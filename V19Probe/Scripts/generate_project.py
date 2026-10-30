"""Generate only an independent V19 iPhone application project."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = []
def add(name, body):
    key = hashlib.sha256(name.encode()).hexdigest()[:24].upper()
    objects.append(f'{key} = {{ {body} }};')
    return key
def quote(value): return json.dumps(value, ensure_ascii=False)
def array(values): return '(' + ', '.join(values) + (',' if values else '') + ')'

sources = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT/'Sources').rglob('*.swift'))
sources += ['Native/V19IMECore.cpp', 'Model/V19FullPinyinFP16.mlpackage']
references, source_builds, resource_builds = [], [], []
for path in sources + ['Assets']:
    kind = 'sourcecode.swift' if path.endswith('.swift') else 'sourcecode.cpp.cpp' if path.endswith('.cpp') else 'folder.mlpackage' if path.endswith('.mlpackage') else 'folder'
    ref = add('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = "<group>";')
    references.append(ref)
    build = add('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};')
    (source_builds if path in sources else resource_builds).append(build)
product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = V19Probe.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('products', f'isa = PBXGroup; children = {array([product])}; name = Products; sourceTree = "<group>";')
group = add('group', f'isa = PBXGroup; children = {array(references+[products])}; sourceTree = "<group>";')
source_phase = add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(source_builds)}; runOnlyForDeploymentPostprocessing = 0;')
resource_phase = add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;')
framework_phase = add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs = []
for mode in ['Debug','Release']:
    settings = {
        'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'18.0','SWIFT_VERSION':'5.0',
        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O',
        'PRODUCT_BUNDLE_IDENTIFIER':'local.che.v19probe','PRODUCT_NAME':'$(TARGET_NAME)',
        'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic',
        'INFOPLIST_KEY_CFBundleDisplayName':'澈 V19 测试',
        'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
        'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
        'INFOPLIST_KEY_UIFileSharingEnabled':'YES',
        'INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace':'YES',
        'TARGETED_DEVICE_FAMILY':'1,2','CURRENT_PROJECT_VERSION':'2','MARKETING_VERSION':'1.0',
        'ENABLE_USER_SCRIPT_SANDBOXING':'YES',
        'SWIFT_OBJC_BRIDGING_HEADER':'Sources/V19Bridge.h',
        'HEADER_SEARCH_PATHS':'$(SRCROOT)/Native/include',
        'CLANG_CXX_LANGUAGE_STANDARD':'c++17', 'CLANG_CXX_LIBRARY':'libc++',
        'OTHER_LDFLAGS':'$(inherited) -lc++',
        'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption':'NO',
    }
    body=' '.join(f'{key} = {quote(value)};' for key,value in settings.items())
    configs.append(add('config:'+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {mode};'))
configuration_list=add('configurations', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=add('target', f'isa = PBXNativeTarget; buildConfigurationList = {configuration_list}; buildPhases = {array([source_phase,framework_phase,resource_phase])}; buildRules = (); dependencies = (); name = V19Probe; productName = V19Probe; productReference = {product}; productType = "com.apple.product-type.application";')
project=add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {configuration_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([target])};')
destination=ROOT/'V19Probe.xcodeproj'; destination.mkdir(exist_ok=True)
(destination/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n',encoding='utf-8')
scheme=ET.Element('Scheme',LastUpgradeVersion='1600',version='1.3')
build=ET.SubElement(scheme,'BuildAction',parallelizeBuildables='YES',buildImplicitDependencies='YES')
entries=ET.SubElement(build,'BuildActionEntries')
entry=ET.SubElement(entries,'BuildActionEntry',**{f'buildFor{k}':'YES' for k in ['Testing','Running','Profiling','Archiving','Analyzing']})
def reference(parent):
    ET.SubElement(parent,'BuildableReference',BuildableIdentifier='primary',BlueprintIdentifier=target,
                  BuildableName='V19Probe.app',BlueprintName='V19Probe',ReferencedContainer='container:V19Probe.xcodeproj')
reference(entry)
launch=ET.SubElement(scheme,'LaunchAction',buildConfiguration='Release',selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB',launchStyle='0',useCustomWorkingDirectory='NO',ignoresPersistentStateOnLaunch='NO',debugDocumentVersioning='YES',debugServiceExtension='internal',allowLocationSimulation='YES')
reference(ET.SubElement(launch,'BuildableProductRunnable',runnableDebuggingMode='0'))
profile=ET.SubElement(scheme,'ProfileAction',buildConfiguration='Release',shouldUseLaunchSchemeArgsEnv='YES',savedToolIdentifier='',useCustomWorkingDirectory='NO',debugDocumentVersioning='YES')
reference(ET.SubElement(profile,'BuildableProductRunnable',runnableDebuggingMode='0'))
ET.SubElement(scheme,'AnalyzeAction',buildConfiguration='Debug')
ET.SubElement(scheme,'ArchiveAction',buildConfiguration='Release',revealArchiveInOrganizer='YES')
schemes=destination/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
ET.ElementTree(scheme).write(schemes/'V19Probe.xcscheme',encoding='utf-8',xml_declaration=True)
print(destination)
