#!/usr/bin/env python3
"""Generate an independent iOS probe project, with no third-party build tools."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path)
    parser.add_argument("--compiled-model-directory", type=Path)
    args = parser.parse_args()
    model_directory = args.model_directory or ROOT / "Models/Qwen3.5-0.8B-IME-Q4-Optimized"
    if args.model_directory is None and not model_directory.exists():
        model_directory = ROOT / "Models/Qwen3.5-0.8B-IME-Q4-SplitHead-Rank4"
        if not model_directory.exists():
            model_directory = ROOT / "Models/Qwen3.5-0.8B-IME-Q4-SplitHead"
            if not model_directory.exists():
                model_directory = ROOT / "Models/Qwen3.5-0.8B-IME-Q4"
    model_directory = model_directory.resolve()
    info = json.loads((model_directory / "model-info.json").read_text(encoding="utf-8"))
    names = ["chunk_" + suffix for suffix in "abcd"] + [head["name"] for head in info.get("headModels", [])]
    compiled = args.compiled_model_directory.resolve() if args.compiled_model_directory else None
    model_root = compiled or model_directory
    extension = ".mlmodelc" if compiled else ".mlpackage"
    model_sources = [(model_root / (name + extension)).relative_to(ROOT).as_posix() for name in names]
    if not all((ROOT / path).is_dir() for path in model_sources):
        raise FileNotFoundError("Missing model package; prepare the selected model first")
    objects = []
    def add(name, definition):
        key = identifier(name)
        objects.append(f"{key} = {{ {definition} }};")
        return key
    def quote(text):
        return json.dumps(text)
    def listing(items):
        return "(" + ", ".join(items) + ("," if items else "") + ")"
    sources = ["ProbeApp/ANEProbeApp.swift", "Sources/QwenANERuntime/QwenANE.swift",
               "Sources/QwenANERuntime/ANEPlan.swift"] + ([] if compiled else model_sources)
    resources = ["ProbeApp/fixture.json", "work/probe-assets/Qwen3.5-0.8B-IME-Q4",
                 "THIRD_PARTY_NOTICES.txt", "LICENSE-QWEN.txt"] + (model_sources if compiled else [])
    references, source_builds, resource_builds = [], [], []
    for path in sources + resources:
        kind = ("sourcecode.swift" if path.endswith(".swift") else
                "folder.mlpackage" if path.endswith(".mlpackage") else
                "folder.mlmodelc" if path.endswith(".mlmodelc") else
                "folder" if path.startswith("work/probe-assets/") else
                "text.json" if path.endswith(".json") else "text")
        reference = add("file:" + path, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = \"<group>\";")
        references.append(reference)
        build = add("build:" + path, f"isa = PBXBuildFile; fileRef = {reference};")
        (source_builds if path in sources else resource_builds).append(build)
    product = add("product", "isa = PBXFileReference; explicitFileType = wrapper.application; path = ANEProbe.app; sourceTree = BUILT_PRODUCTS_DIR;")
    products = add("products", f"isa = PBXGroup; children = {listing([product])}; name = Products; sourceTree = \"<group>\";")
    group = add("group", f"isa = PBXGroup; children = {listing(references + [products])}; sourceTree = \"<group>\";")
    source_phase = add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {listing(source_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    resource_phase = add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {listing(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    framework_phase = add("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    configurations = []
    for mode in ["Debug", "Release"]:
        optimization = "-Onone" if mode == "Debug" else "-O"
        settings = {
            "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "SWIFT_VERSION": "5.0", "SWIFT_OPTIMIZATION_LEVEL": optimization,
            "PRODUCT_BUNDLE_IDENTIFIER": "local.qwen.aneprobe", "PRODUCT_NAME": "$(TARGET_NAME)",
            "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Automatic",
            "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2", "CURRENT_PROJECT_VERSION": "8",
            "MARKETING_VERSION": "0.8", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"
        }
        body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
        configurations.append(add("config:" + mode, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {mode};"))
    configuration_list = add("configurations", f"isa = XCConfigurationList; buildConfigurations = {listing(configurations)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target = add("target", f"isa = PBXNativeTarget; buildConfigurationList = {configuration_list}; buildPhases = {listing([source_phase, framework_phase, resource_phase])}; buildRules = (); dependencies = (); name = ANEProbe; productName = ANEProbe; productReference = {product}; productType = \"com.apple.product-type.application\";")
    project = add("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {configuration_list}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = {listing([target])};")
    destination = ROOT / "ANEProbe.xcodeproj"
    destination.mkdir(exist_ok=True)
    (destination / "project.pbxproj").write_text("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n" + "\n".join(objects) + f"\n}}; rootObject = {project}; }}\n")
    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", **{f"buildFor{key}": "YES" for key in ["Testing", "Running", "Profiling", "Archiving", "Analyzing"]})
    def reference(parent):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target,
                      BuildableName="ANEProbe.app", BlueprintName="ANEProbe", ReferencedContainer="container:ANEProbe.xcodeproj")
    reference(entry)
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Release", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    scheme_directory = destination / "xcshareddata/xcschemes"
    scheme_directory.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(scheme_directory / "ANEProbe.xcscheme", encoding="utf-8", xml_declaration=True)
    print(destination)


if __name__ == "__main__":
    main()
