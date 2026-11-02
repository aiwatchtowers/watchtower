#!/bin/bash
# Render only the PlansShotFixtures entries also registered in DesignShotCatalog.
# Uses the real DesignKit, fixture views and ViewRenderProbe without linking ML.
set -euo pipefail
cd "$(dirname "$0")/../.."
build_dir="${TMPDIR:-/tmp}/watchtower-plans-render"
mkdir -p "$build_dir/modules" docs/design/mockups/plans
xcode_dir="$(xcode-select -p)"
platform_dir="$xcode_dir/Platforms/MacOSX.platform/Developer"
framework_dir="$platform_dir/Library/Frameworks"
shared_dir="$xcode_dir/../SharedFrameworks"
args=(-module-cache-path "$build_dir/cache" -I "$build_dir/modules" -L "$build_dir/modules")
swiftc -emit-library -emit-module -module-name WatchtowerDesign "${args[@]}" \
    WatchtowerKit/Sources/WatchtowerDesign/*.swift \
    -o "$build_dir/modules/libWatchtowerDesign.dylib" -emit-module-path "$build_dir/modules/WatchtowerDesign.swiftmodule"
swiftc -emit-library -emit-module -module-name DesignKit "${args[@]}" -lWatchtowerDesign \
    WatchtowerDesktop/Sources/DesignKit/*.swift \
    -o "$build_dir/modules/libDesignKit.dylib" -emit-module-path "$build_dir/modules/DesignKit.swiftmodule"
swiftc -parse-as-library "${args[@]}" -F "$framework_dir" -I "$platform_dir/usr/lib" \
    -L "$platform_dir/usr/lib" -lXCTestSwiftSupport -lWatchtowerDesign -lDesignKit \
    -Xlinker -rpath -Xlinker "$build_dir/modules" \
    -Xlinker -rpath -Xlinker "$framework_dir" \
    -Xlinker -rpath -Xlinker "$platform_dir/usr/lib" \
    -Xlinker -rpath -Xlinker "$shared_dir" \
    scripts/design/RenderPlansMockups.swift WatchtowerDesktop/Tests/ViewRenderProbe.swift \
    WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Plans.swift \
    WatchtowerDesktop/Tests/DesignShots/PlansMockupModelTests.swift -o "$build_dir/render"
"$build_dir/render" --test
"$build_dir/render" "${1:-docs/design/mockups/plans}"
