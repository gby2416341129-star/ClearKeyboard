#!/usr/bin/env python3
"""Generate a dependency-free Xcode project using stable object IDs. Requires only Python 3."""
import hashlib
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
def arr(values): return "(" + ", ".join(values) + ")"
def obj(identity, isa, **fields):
    identifier = uid(identity)
    objects[identifier] = "{ isa = " + isa + "; " + " ".join(f"{key} = {value};" for key, value in fields.items()) + " }"
    return identifier
def reference(path, kind=None):
    if kind is None:
        kind = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcprivacy": "text.xml", ".xcconfig": "text.xcconfig", ".entitlements": "text.plist.entitlements", ".xcassets": "folder.assetcatalog", ".icon": "folder.icon", ".cpp": "sourcecode.cpp.cpp", ".h": "sourcecode.c.h"}.get(Path(path).suffix, "file")
    return obj("file:" + path, "PBXFileReference", lastKnownFileType=q(kind), path=q(path), sourceTree=q("<group>"))
def phase(target, name, isa, files, **fields):
    builds = []
    for path in files:
        ref = refs[path]
        builds.append(obj(f"build:{target}:{name}:{path}", "PBXBuildFile", fileRef=ref))
    return obj(f"phase:{target}:{name}", isa, buildActionMask="2147483647", files=arr(builds), runOnlyForDeploymentPostprocessing="0", **fields)

if __name__ == "__main__":
    sources = sorted(p.relative_to(ROOT).as_posix() for directory in ["App", "Core", "SharedUI", "KeyboardExtension"] for p in (ROOT / directory).glob("*.swift"))
    resources = ["SharedUI/Resources/ToolIcons", "SharedUI/Resources/BrandMark.png", "Core/Resources/Rime", "Core/Resources/associations.clx", "Core/Resources/pinyin.clx", "Core/Resources/english.clx", "Core/Resources/pinyin-corrections.clx", "Config/PrivacyInfo.xcprivacy"]
    licenses = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Licenses").glob("*.txt"))
    config = ["Config/Project.xcconfig", "Config/App-Info.plist", "Config/Keyboard-Info.plist", "Config/App.entitlements", "Config/Keyboard.entitlements"]
    asset = "App/Assets.xcassets"
    app_icon = "App/ClearAppIcon.icon"
    bridge = "CRime/ClearRime.cpp"
    refs = {path: reference(path, "folder" if path in ("Core/Resources/Rime", "SharedUI/Resources/ToolIcons") else None) for path in sources + resources + licenses + config + [asset, app_icon, bridge]}
    rime_package = obj("package:rime", "XCRemoteSwiftPackageReference", repositoryURL=q("https://github.com/ghostflyby/librime-xcframework.git"), requirement='{ kind = exactVersion; version = "1.17.0-pack.10.0.0"; }')
    def rime_product(target):
        product = obj("package-product:rime:"+target, "XCSwiftPackageProductDependency", package=rime_package, productName=q("RimeStatic"))
        build = obj("package-build:rime:"+target, "PBXBuildFile", productRef=product)
        return product, build
    app_rime, app_rime_build = rime_product("app")
    ext_rime, ext_rime_build = rime_product("ext")
    app_product = obj("product:app", "PBXFileReference", explicitFileType=q("wrapper.application"), path=q("ClearKeyboard.app"), sourceTree=q("BUILT_PRODUCTS_DIR"))
    ext_product = obj("product:extension", "PBXFileReference", explicitFileType=q("wrapper.app-extension"), path=q("ClearKeyboardExtension.appex"), sourceTree=q("BUILT_PRODUCTS_DIR"))
    products = obj("group:products", "PBXGroup", children=arr([app_product, ext_product]), name=q("Products"), sourceTree=q("<group>"))
    runtime_sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "NativeTests").glob("*.swift"))
    for path in runtime_sources: refs[path] = reference(path)
    ui_sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "UITests").glob("*.swift"))
    for path in ui_sources: refs[path] = reference(path)
    test_product = obj("product:runtime-tests", "PBXFileReference", explicitFileType=q("wrapper.cfbundle"), path=q("ClearKeyboardRuntimeTests.xctest"), sourceTree=q("BUILT_PRODUCTS_DIR"))
    ui_product = obj("product:ui-tests", "PBXFileReference", explicitFileType=q("wrapper.cfbundle"), path=q("ClearKeyboardUITests.xctest"), sourceTree=q("BUILT_PRODUCTS_DIR"))
    objects[products] = "{ isa = PBXGroup; children = " + arr([app_product, ext_product, test_product, ui_product]) + "; name = Products; sourceTree = \"<group>\"; }"
    group = obj("group:main", "PBXGroup", children=arr(list(refs.values()) + [products]), sourceTree=q("<group>"))
    common_settings = {"SDKROOT": "iphoneos", "CLANG_ENABLE_OBJC_ARC": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17", "SWIFT_VERSION": "5.0", "SWIFT_OBJC_BRIDGING_HEADER": "CRime/include/ClearRime.h", "CLANG_CXX_LANGUAGE_STANDARD": "c++17", "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Accelerate"}
    def configurations(target, extra):
        values = []
        for mode in ["Debug", "Release"]:
            settings = dict(common_settings, **extra)
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "GCC_OPTIMIZATION_LEVEL": "0" if mode == "Debug" else "3", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"})
            if mode == "Debug":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
                settings["ENABLE_TESTABILITY"] = "YES"
            rendered = "{ " + " ".join(f"{key} = {q(value)};" for key, value in settings.items()) + " }"
            values.append(obj(f"config:{target}:{mode}", "XCBuildConfiguration", baseConfigurationReference=refs["Config/Project.xcconfig"], buildSettings=rendered, name=q(mode)))
        return obj(f"configs:{target}", "XCConfigurationList", buildConfigurations=arr(values), defaultConfigurationIsVisible="0", defaultConfigurationName=q("Release"))
    project_configs = configurations("project", {})
    app_configs = configurations("app", {"PRODUCT_BUNDLE_IDENTIFIER": "$(CLEAR_BASE_BUNDLE_IDENTIFIER)", "PRODUCT_NAME": "ClearKeyboard", "INFOPLIST_FILE": "Config/App-Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/App.entitlements", "ASSETCATALOG_COMPILER_APPICON_NAME": "ClearAppIcon", "GENERATE_INFOPLIST_FILE": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "SWIFT_EMIT_LOC_STRINGS": "YES"})
    ext_configs = configurations("ext", {"PRODUCT_BUNDLE_IDENTIFIER": "$(CLEAR_BASE_BUNDLE_IDENTIFIER).Keyboard", "PRODUCT_NAME": "ClearKeyboardExtension", "INFOPLIST_FILE": "Config/Keyboard-Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/Keyboard.entitlements", "GENERATE_INFOPLIST_FILE": "NO", "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"})
    shared = [path for path in sources if path.startswith(("Core/", "SharedUI/"))]
    ext_phases = [phase("ext", "Sources", "PBXSourcesBuildPhase", shared + [bridge] + [p for p in sources if p.startswith("KeyboardExtension/")]), obj("phase:ext:Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=arr([ext_rime_build]), runOnlyForDeploymentPostprocessing="0"), phase("ext", "Resources", "PBXResourcesBuildPhase", [p for p in resources if p != "Core/Resources/Rime"] + licenses)]
    ext = obj("target:extension", "PBXNativeTarget", packageProductDependencies=arr([ext_rime]), buildConfigurationList=ext_configs, buildPhases=arr(ext_phases), buildRules="()", dependencies="()", name=q("ClearKeyboardExtension"), productName=q("ClearKeyboardExtension"), productReference=ext_product, productType=q("com.apple.product-type.app-extension"))
    proxy = obj("proxy:extension", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType="1", remoteGlobalIDString=ext, remoteInfo=q("ClearKeyboardExtension"))
    dependency = obj("dependency:extension", "PBXTargetDependency", target=ext, targetProxy=proxy)
    embed_build = obj("embed:extension", "PBXBuildFile", fileRef=ext_product, settings="{ ATTRIBUTES = (RemoveHeadersOnCopy, CodeSignOnCopy); }")
    embed = obj("phase:app:Embed", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath=q(""), dstSubfolderSpec="13", files=arr([embed_build]), name=q("Embed App Extensions"), runOnlyForDeploymentPostprocessing="0")
    app_phases = [phase("app", "Sources", "PBXSourcesBuildPhase", shared + [bridge] + [p for p in sources if p.startswith("App/")]), obj("phase:app:Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=arr([app_rime_build]), runOnlyForDeploymentPostprocessing="0"), phase("app", "Resources", "PBXResourcesBuildPhase", resources + licenses + [asset, app_icon]), embed]
    app = obj("target:app", "PBXNativeTarget", packageProductDependencies=arr([app_rime]), buildConfigurationList=app_configs, buildPhases=arr(app_phases), buildRules="()", dependencies=arr([dependency]), name=q("ClearKeyboard"), productName=q("ClearKeyboard"), productReference=app_product, productType=q("com.apple.product-type.application"))
    test_configs = configurations("runtime-tests", {"PRODUCT_BUNDLE_IDENTIFIER": "$(CLEAR_BASE_BUNDLE_IDENTIFIER).RuntimeTests", "PRODUCT_NAME": "ClearKeyboardRuntimeTests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/ClearKeyboard.app/ClearKeyboard", "BUNDLE_LOADER": "$(TEST_HOST)", "CODE_SIGN_ENTITLEMENTS": "", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"})
    app_proxy = obj("proxy:app", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType="1", remoteGlobalIDString=app, remoteInfo=q("ClearKeyboard"))
    app_dependency = obj("dependency:app", "PBXTargetDependency", target=app, targetProxy=app_proxy)
    test_phases = [phase("runtime-tests", "Sources", "PBXSourcesBuildPhase", shared + [p for p in sources if p.startswith("App/") and p != "App/ClearKeyboardApp.swift"] + ["KeyboardExtension/KeyboardViewController.swift"] + runtime_sources), phase("runtime-tests", "Frameworks", "PBXFrameworksBuildPhase", []), phase("runtime-tests", "Resources", "PBXResourcesBuildPhase", [])]
    runtime_target = obj("target:runtime-tests", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=arr(test_phases), buildRules="()", dependencies=arr([app_dependency]), name=q("ClearKeyboardRuntimeTests"), productName=q("ClearKeyboardRuntimeTests"), productReference=test_product, productType=q("com.apple.product-type.bundle.unit-test"))
    ui_configs = configurations("ui-tests", {"PRODUCT_BUNDLE_IDENTIFIER": "$(CLEAR_BASE_BUNDLE_IDENTIFIER).UITests", "PRODUCT_NAME": "ClearKeyboardUITests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "ClearKeyboard", "SWIFT_OBJC_BRIDGING_HEADER": "", "CODE_SIGN_ENTITLEMENTS": "", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"})
    ui_phases = [phase("ui-tests", "Sources", "PBXSourcesBuildPhase", ui_sources), phase("ui-tests", "Frameworks", "PBXFrameworksBuildPhase", []), phase("ui-tests", "Resources", "PBXResourcesBuildPhase", [])]
    ui_target = obj("target:ui-tests", "PBXNativeTarget", buildConfigurationList=ui_configs, buildPhases=arr(ui_phases), buildRules="()", dependencies=arr([app_dependency]), name=q("ClearKeyboardUITests"), productName=q("ClearKeyboardUITests"), productReference=ui_product, productType=q("com.apple.product-type.bundle.ui-testing"))
    project = obj("project", "PBXProject", packageReferences=arr([rime_package]), attributes="{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }", buildConfigurationList=project_configs, compatibilityVersion=q("Xcode 14.0"), developmentRegion=q("zh-Hans"), hasScannedForEncodings="0", knownRegions=arr([q("zh-Hans"), q("en"), q("Base")]), mainGroup=group, productRefGroup=products, projectDirPath=q(""), projectRoot=q(""), targets=arr([app, ext, runtime_target, ui_target]))
    folder = ROOT / "ClearKeyboard.xcodeproj"
    folder.mkdir(exist_ok=True)
    text = "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
    text += "\n".join(f"{identifier} = {body};" for identifier, body in objects.items())
    text += f"\n}}; rootObject = {project}; }}\n"
    (folder / "project.pbxproj").write_text(text, encoding="utf-8")
    schemes = folder / "xcshareddata" / "xcschemes"; schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="ClearKeyboard.app" BlueprintName="ClearKeyboard" ReferencedContainer="container:ClearKeyboard.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemes / "ClearKeyboard.xcscheme").write_text(scheme, encoding="utf-8")
    test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{runtime_target}" BuildableName="ClearKeyboardRuntimeTests.xctest" BlueprintName="ClearKeyboardRuntimeTests" ReferencedContainer="container:ClearKeyboard.xcodeproj"/>'
    runtime_scheme = scheme.replace('<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>', f'<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>')
    (schemes / "ClearKeyboardRuntime.xcscheme").write_text(runtime_scheme, encoding="utf-8")
    ui_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="ClearKeyboardUITests.xctest" BlueprintName="ClearKeyboardUITests" ReferencedContainer="container:ClearKeyboard.xcodeproj"/>'
    ui_scheme = runtime_scheme.replace(test_ref, ui_ref)
    (schemes / "ClearKeyboardUI.xcscheme").write_text(ui_scheme, encoding="utf-8")
    print(f"Generated {len(objects)} Xcode objects, {len(sources)} Swift sources, app + keyboard extension.")
