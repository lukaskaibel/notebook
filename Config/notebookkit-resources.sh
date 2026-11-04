#!/bin/sh
# NotebookKit's resources, once in the app: the bundles of NotebookKit and of the packages it links (the icon's passes,
# SwiftMath's fonts), which Xcode copies into every app and extension that links NotebookKit, about 8 MB each time.
# A "NotebookKit's resources" build phase of the app and of the Quick Look and thumbnail extensions runs this, with the
# copies Xcode made in the target's Resources among its input files.
#
# The app moves its copies into the NotebookKit framework before it embeds the framework, and the extensions remove
# theirs. Bundle.module finds them in the framework, in the app and in the extensions alike, as it does for a package
# linked into a framework; Xcode puts none there itself. The app also puts NotebookKit's privacy manifest there, where
# the App Store looks for a framework's.
set -eu

app=false
if [ "$PRODUCT_TYPE" = "com.apple.product-type.application" ]; then
    app=true
    # Where Xcode builds the framework, and the app's Embed Frameworks phase takes it from: in PackageFrameworks when
    # building, in the products folder itself when archiving.
    framework=
    for candidate in "$BUILT_PRODUCTS_DIR/PackageFrameworks/NotebookKit.framework" \
                     "$BUILT_PRODUCTS_DIR/NotebookKit.framework"; do
        if [ -e "$candidate/NotebookKit" ]; then framework=$candidate; break; fi
    done
    if [ -z "$framework" ]; then
        echo "error: NotebookKit.framework isn't in $BUILT_PRODUCTS_DIR or its PackageFrameworks folder."
        exit 1
    fi
    # A Mac framework keeps its resources in Versions/A, one for iPhone and iPad at its top.
    resources=$framework
    [ -d "$framework/Versions/A/Resources" ] && resources=$framework/Versions/A/Resources
fi

i=0
while [ "$i" -lt "$SCRIPT_INPUT_FILE_COUNT" ]; do
    eval "input=\$SCRIPT_INPUT_FILE_$i"
    i=$((i + 1))
    case "$input" in
    *.bundle)
        if $app; then
            rm -rf "$resources/$(basename "$input")"
            mv "$input" "$resources/"
        else
            rm -rf "$input"
        fi
        ;;
    *.xcprivacy)
        cp "$input" "$resources/PrivacyInfo.xcprivacy"
        ;;
    esac
done
touch "$SCRIPT_OUTPUT_FILE_0"
