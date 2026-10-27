# The App Store Connect API's App Asset Library, which fastlane's deliver doesn't know yet. The creative assets of
# iOS 27 (the product page header and the search result) and the app previews are uploaded to the app's library
# and placed on a version's localization; from there they go to App Review with the version.
#
# A dry run only reads: App Store Connect's specs for each placement (its reference data), the app's library and the
# version it would place on. Every request that would change something goes through `change`, which on a dry run
# says what it would send instead of sending it.
require "json"
require "net/http"
require "open3"
require "uri"

class AssetLibrary
  HOST = "https://api.appstoreconnect.apple.com".freeze
  # Where a version can still be changed.
  EDITABLE = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].freeze

  def initialize(token, bundle_id, dry_run:)
    @token = token
    @bundle_id = bundle_id
    @dry_run = dry_run
  end

  def dry_run?
    @dry_run
  end

  def app_id
    @app_id ||= get("/v1/apps", "filter[bundleId]" => @bundle_id).fetch("data").first&.fetch("id") ||
                raise("No app with the bundle identifier #{@bundle_id} in App Store Connect.")
  end

  def library_id
    @library_id ||= get("/v1/apps/#{app_id}/assetLibrary").dig("data", "id")
  end

  # The spec of App Store Connect's reference data that the video matches, for this placement type and group; raises
  # with what doesn't fit when it matches none.
  def check_video(file, placement_type, group)
    mapping = reference.fetch("placementTypes").find { |type| type["placementTypeId"] == placement_type }
    ids = mapping&.fetch("specMappings")&.find { |m| m["placementGroupId"] == group }&.fetch("specs")
    raise "App Store Connect has no #{placement_type} for #{group}." unless ids

    specs = reference.fetch("videoSpecs").select { |spec| ids.include?(spec["specId"]) }
    info = probe(file)
    match = specs.find { |spec| fits?(spec, info, file) }
    return match if match

    raise "#{File.basename(file)} (#{describe(info)}) fits none of App Store Connect's specs for #{placement_type} " \
          "#{group}: #{specs.map { |spec| spec['shortName'] }.join(', ')}."
  end

  # The version's localization to place on: its id, or nil and why not.
  def localization(platform, version, locale)
    versions = get("/v1/apps/#{app_id}/appStoreVersions", "filter[platform]" => platform,
                                                         "filter[versionString]" => version).fetch("data")
    found = versions.first
    return [nil, "#{platform} #{version} doesn't exist in App Store Connect yet"] unless found

    state = found.dig("attributes", "appStoreState")
    return [nil, "#{platform} #{version} is #{state.downcase.tr('_', ' ')}, so it can't be changed"] unless EDITABLE.include?(state)

    localizations = get("/v1/appStoreVersions/#{found['id']}/appStoreVersionLocalizations").fetch("data")
    chosen = localizations.find { |l| l.dig("attributes", "locale") == locale }
    chosen ? [chosen["id"], "#{platform} #{version} (#{locale})"] : [nil, "#{platform} #{version} has no #{locale}"]
  end

  # Reserves the video in the library, uploads it in the parts App Store Connect asks for and commits it. Returns its
  # id, or nil on a dry run.
  def upload_video(file, category:, name:, frame: nil)
    attributes = { fileName: File.basename(file), fileSize: File.size(file), category: category, referenceName: name }
    attributes[:previewFrameTimeCode] = time_code(frame, file) if frame
    reserved = change(:post, "/v1/appAssetLibraryVideos",
                      data: { type: "appAssetLibraryVideos", attributes: attributes,
                              relationships: { assetLibrary: { data: { type: "appAssetLibraries", id: library_id } } } })
    return nil unless reserved

    id = reserved.dig("data", "id")
    send_parts(file, reserved.dig("data", "attributes", "uploadOperations"))
    change(:patch, "/v1/appAssetLibraryVideos/#{id}",
           data: { type: "appAssetLibraryVideos", id: id, attributes: { uploaded: true } })
    # Processing goes on after this; a placement can be made meanwhile. Only a quick failure is waited for.
    6.times do
      state = get("/v1/appAssetLibraryVideos/#{id}").dig("data", "attributes")
      raise "App Store Connect couldn't process #{File.basename(file)}: #{state['stateDetails']}" if state["state"] == "FAILED"
      break if state["state"] == "PREPARE_FOR_SUBMISSION"

      sleep(10)
    end
    id
  end

  # Puts the video on the localization in place of what that placement type and group show there now.
  def place(video_id, placement_type, group, localization_id)
    existing = get("/v1/appStoreVersionLocalizations/#{localization_id}/placements",
                   "filter[placementType]" => placement_type, "filter[placementGroup]" => group).fetch("data")
    existing.each { |placement| change(:delete, "/v1/appAssetLibraryPlacements/#{placement['id']}") }
    change(:post, "/v1/appAssetLibraryPlacements",
           data: { type: "appAssetLibraryPlacements",
                   attributes: { placementType: placement_type, placementGroup: group },
                   relationships: { video: { data: { type: "appAssetLibraryVideos", id: video_id || "(new)" } },
                                    appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations",
                                                                           id: localization_id } } } })
  end

  private

  def reference
    @reference ||= get("/v1/appAssetLibraryRefData").fetch("data").first.fetch("attributes")
  end

  def get(path, query = {})
    request(Net::HTTP::Get, path, nil, query)
  end

  # A request that changes something: sent, or on a dry run only described.
  def change(method, path, body = nil)
    if @dry_run
      summary = body && body.dig(:data, :attributes)&.reject { |key, _| key == :uploaded }
      puts "  would #{method.to_s.upcase} #{path}#{summary ? " #{JSON.generate(summary)}" : ''}"
      return nil
    end
    request({ post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(method), path, body)
  end

  def request(kind, path, body, query = {})
    uri = URI(HOST + path)
    uri.query = URI.encode_www_form(query) unless query.empty?
    @token.refresh! if @token.expired?
    req = kind.new(uri)
    req["Authorization"] = "Bearer #{@token.text}"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "#{kind::METHOD} #{path}: HTTP #{res.code} #{res.body}" unless res.code.to_i < 300

    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  # The upload URLs need no token; each part is its own request.
  def send_parts(file, operations)
    File.open(file, "rb") do |f|
      operations.each do |operation|
        f.seek(operation["offset"])
        uri = URI(operation["url"])
        req = Net::HTTP.const_get(operation["method"].capitalize).new(uri)
        (operation["requestHeaders"] || []).each { |header| req[header["name"]] = header["value"] }
        req.body = f.read(operation["length"])
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
        raise "Uploading #{File.basename(file)}: HTTP #{res.code}" unless res.code.to_i < 300
      end
    end
  end

  # "00:00:05:00" as it is; a negative number of seconds as that long before the end, at 30 frames a second.
  def time_code(frame, file)
    return frame unless frame.is_a?(Numeric)

    at = probe(file)[:seconds] + frame
    format("%02d:%02d:%02d:%02d", at / 3600, at / 60 % 60, at % 60, (at % 1 * 30).floor)
  end

  def probe(file)
    out, status = Open3.capture2("ffprobe", "-v", "error", "-show_entries",
                                 "stream=codec_type,width,height,r_frame_rate:format=duration", "-of", "json", file)
    raise "ffprobe can't read #{file}" unless status.success?

    json = JSON.parse(out)
    video = json["streams"].find { |s| s["codec_type"] == "video" } || {}
    num, den = video.fetch("r_frame_rate", "0/1").split("/").map(&:to_f)
    { width: video["width"], height: video["height"], fps: den.zero? ? 0 : num / den,
      seconds: json.dig("format", "duration").to_f, audio: json["streams"].any? { |s| s["codec_type"] == "audio" } }
  end

  def fits?(spec, info, file)
    d = spec["dimensions"]
    (d["minWidth"]..d["maxWidth"]).cover?(info[:width]) && (d["minHeight"]..d["maxHeight"]).cover?(info[:height]) &&
      spec["frameRates"].any? { |r| info[:fps].between?(r["minFps"] - 0.01, r["maxFps"] + 0.01) } &&
      info[:seconds].between?(seconds(spec.dig("duration", "min")), seconds(spec.dig("duration", "max"))) &&
      spec["fileExtensions"].include?(File.extname(file).downcase) && File.size(file) <= spec["maxFileSize"] &&
      (!spec["audioRequired"] || info[:audio])
  end

  # "PT15S", "PT1M" in seconds.
  def seconds(duration)
    minutes = duration[/(\d+)M/, 1].to_f
    minutes * 60 + duration[/(\d+(?:\.\d+)?)S/, 1].to_f
  end

  def describe(info)
    "#{info[:width]} x #{info[:height]}, #{info[:fps].round(2)} fps, #{info[:seconds].round(1)} s#{info[:audio] ? ', audio' : ''}"
  end
end
