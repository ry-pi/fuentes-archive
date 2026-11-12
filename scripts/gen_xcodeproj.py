#!/usr/bin/env python3
"""Write FuentesArchive.xcodeproj. Re-run after adding Swift files."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = [
    "FuentesArchive/App/FuentesArchiveApp.swift",
    "FuentesArchive/Model/Library.swift",
    "FuentesArchive/Parsing/HTMLScanner.swift",
    "FuentesArchive/Parsing/ListingParser.swift",
    "FuentesArchive/Parsing/StreamResolver.swift",
    "FuentesArchive/Parsing/TSRemuxer.swift",
    "FuentesArchive/Services/AppModel.swift",
    "FuentesArchive/Services/BackgroundScheduler.swift",
    "FuentesArchive/Services/DebugLog.swift",
    "FuentesArchive/Services/DownloadManager.swift",
    "FuentesArchive/Services/Playback.swift",
    "FuentesArchive/Services/RumbleClient.swift",
    "FuentesArchive/Views/ArchiveViews.swift",
    "FuentesArchive/Views/PlayerTab.swift",
]
APP_RESOURCES = [
    "FuentesArchive/Assets.xcassets",
    "FuentesArchive/PrivacyInfo.xcprivacy",
]
TEST_SOURCES = ["FuentesArchiveTests/ArchiveTests.swift"]
TEST_RESOURCES = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "FuentesArchiveTests" / "Fixtures").iterdir() if path.is_file())


def uid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def q(text: str) -> str:
    if any(ch in text for ch in " /"):
        return f'"{text}"'
    return text


APP_TARGET = uid("target-app")
TEST_TARGET = uid("target-test")
PROJECT = uid("project")
APP_PRODUCT = uid("product-app")
TEST_PRODUCT = uid("product-test")
APP_SOURCES_PHASE = uid("phase-sources-app")
APP_RESOURCES_PHASE = uid("phase-resources-app")
APP_FRAMEWORKS_PHASE = uid("phase-frameworks-app")
TEST_SOURCES_PHASE = uid("phase-sources-test")
TEST_RESOURCES_PHASE = uid("phase-resources-test")
TEST_FRAMEWORKS_PHASE = uid("phase-frameworks-test")
PROXY = uid("proxy")
DEPENDENCY = uid("dependency")
GROUP_MAIN = uid("group-main")
GROUP_APP = uid("group-app")
GROUP_TEST = uid("group-test")
GROUP_PRODUCTS = uid("group-products")
CONFIG_LIST_PROJECT = uid("cfglist-project")
CONFIG_LIST_APP = uid("cfglist-app")
CONFIG_LIST_TEST = uid("cfglist-test")
CFG_PROJECT_DEBUG = uid("cfg-project-debug")
CFG_PROJECT_RELEASE = uid("cfg-project-release")
CFG_APP_DEBUG = uid("cfg-app-debug")
CFG_APP_RELEASE = uid("cfg-app-release")
CFG_TEST_DEBUG = uid("cfg-test-debug")
CFG_TEST_RELEASE = uid("cfg-test-release")


def file_ref(path: str) -> str:
    return uid("fileref-" + path)


def build_file(path: str) -> str:
    return uid("build-" + path)


def file_type(path: str) -> str:
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".xcprivacy"):
        return "text.xml"
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    if path.endswith(".html"):
        return "text.html"
    if path.endswith(".json"):
        return "text.json"
    if path.endswith(".m3u8"):
        return "text"
    return "text"


lines: list[str] = []
a = lines.append
a("// !$*UTF8*$!")
a("{")
a("\tarchiveVersion = 1;")
a("\tclasses = {")
a("\t};")
a("\tobjectVersion = 56;")
a("\tobjects = {")
a("")
a("/* Begin PBXBuildFile section */")
for path in APP + APP_RESOURCES + TEST_SOURCES + TEST_RESOURCES:
    a(f"\t\t{build_file(path)} /* {Path(path).name} */ = {{isa = PBXBuildFile; fileRef = {file_ref(path)} /* {Path(path).name} */; }};")
a("/* End PBXBuildFile section */")
a("")
a("/* Begin PBXContainerItemProxy section */")
a(f"\t\t{PROXY} /* PBXContainerItemProxy */ = {{")
a("\t\t\tisa = PBXContainerItemProxy;")
a(f"\t\t\tcontainerPortal = {PROJECT} /* Project object */;")
a("\t\t\tproxyType = 1;")
a(f"\t\t\tremoteGlobalIDString = {APP_TARGET};")
a("\t\t\tremoteInfo = FuentesArchive;")
a("\t\t};")
a("/* End PBXContainerItemProxy section */")
a("")
a("/* Begin PBXFileReference section */")
a(f"\t\t{APP_PRODUCT} /* FuentesArchive.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FuentesArchive.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
a(f"\t\t{TEST_PRODUCT} /* FuentesArchiveTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = FuentesArchiveTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
for path in APP + APP_RESOURCES + TEST_SOURCES + TEST_RESOURCES:
    name = Path(path).name
    rel = str(Path(path).relative_to("FuentesArchive" if path.startswith("FuentesArchive/") else "FuentesArchiveTests"))
    a(f"\t\t{file_ref(path)} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; path = {q(rel)}; sourceTree = \"<group>\"; }};")
a("/* End PBXFileReference section */")
a("")
a("/* Begin PBXFrameworksBuildPhase section */")
for phase, name in ((APP_FRAMEWORKS_PHASE, "App"), (TEST_FRAMEWORKS_PHASE, "Tests")):
    a(f"\t\t{phase} /* Frameworks */ = {{")
    a("\t\t\tisa = PBXFrameworksBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
a("/* End PBXFrameworksBuildPhase section */")
a("")
a("/* Begin PBXGroup section */")
a(f"\t\t{GROUP_MAIN} = {{")
a("\t\t\tisa = PBXGroup;")
a("\t\t\tchildren = (")
a(f"\t\t\t\t{GROUP_APP} /* FuentesArchive */,")
a(f"\t\t\t\t{GROUP_TEST} /* FuentesArchiveTests */,")
a(f"\t\t\t\t{GROUP_PRODUCTS} /* Products */,")
a("\t\t\t);")
a("\t\t\tsourceTree = \"<group>\";")
a("\t\t};")
a(f"\t\t{GROUP_APP} /* FuentesArchive */ = {{")
a("\t\t\tisa = PBXGroup;")
a("\t\t\tchildren = (")
for path in APP + APP_RESOURCES:
    a(f"\t\t\t\t{file_ref(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\tpath = FuentesArchive;")
a("\t\t\tsourceTree = \"<group>\";")
a("\t\t};")
a(f"\t\t{GROUP_TEST} /* FuentesArchiveTests */ = {{")
a("\t\t\tisa = PBXGroup;")
a("\t\t\tchildren = (")
for path in TEST_SOURCES + TEST_RESOURCES:
    a(f"\t\t\t\t{file_ref(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\tpath = FuentesArchiveTests;")
a("\t\t\tsourceTree = \"<group>\";")
a("\t\t};")
a(f"\t\t{GROUP_PRODUCTS} /* Products */ = {{")
a("\t\t\tisa = PBXGroup;")
a("\t\t\tchildren = (")
a(f"\t\t\t\t{APP_PRODUCT} /* FuentesArchive.app */,")
a(f"\t\t\t\t{TEST_PRODUCT} /* FuentesArchiveTests.xctest */,")
a("\t\t\t);")
a("\t\t\tname = Products;")
a("\t\t\tsourceTree = \"<group>\";")
a("\t\t};")
a("/* End PBXGroup section */")
a("")
a("/* Begin PBXNativeTarget section */")
a(f"\t\t{APP_TARGET} /* FuentesArchive */ = {{")
a("\t\t\tisa = PBXNativeTarget;")
a(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_APP} /* Build configuration list for PBXNativeTarget \"FuentesArchive\" */;")
a("\t\t\tbuildPhases = (")
a(f"\t\t\t\t{APP_SOURCES_PHASE} /* Sources */,")
a(f"\t\t\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */,")
a(f"\t\t\t\t{APP_RESOURCES_PHASE} /* Resources */,")
a("\t\t\t);")
a("\t\t\tbuildRules = (")
a("\t\t\t);")
a("\t\t\tdependencies = (")
a("\t\t\t);")
a("\t\t\tname = FuentesArchive;")
a("\t\t\tproductName = FuentesArchive;")
a(f"\t\t\tproductReference = {APP_PRODUCT} /* FuentesArchive.app */;")
a("\t\t\tproductType = \"com.apple.product-type.application\";")
a("\t\t};")
a(f"\t\t{TEST_TARGET} /* FuentesArchiveTests */ = {{")
a("\t\t\tisa = PBXNativeTarget;")
a(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_TEST} /* Build configuration list for PBXNativeTarget \"FuentesArchiveTests\" */;")
a("\t\t\tbuildPhases = (")
a(f"\t\t\t\t{TEST_SOURCES_PHASE} /* Sources */,")
a(f"\t\t\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */,")
a(f"\t\t\t\t{TEST_RESOURCES_PHASE} /* Resources */,")
a("\t\t\t);")
a("\t\t\tbuildRules = (")
a("\t\t\t);")
a("\t\t\tdependencies = (")
a(f"\t\t\t\t{DEPENDENCY} /* PBXTargetDependency */,")
a("\t\t\t);")
a("\t\t\tname = FuentesArchiveTests;")
a("\t\t\tproductName = FuentesArchiveTests;")
a(f"\t\t\tproductReference = {TEST_PRODUCT} /* FuentesArchiveTests.xctest */;")
a("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
a("\t\t};")
a("/* End PBXNativeTarget section */")
a("")
a("/* Begin PBXProject section */")
a(f"\t\t{PROJECT} /* Project object */ = {{")
a("\t\t\tisa = PBXProject;")
a("\t\t\tattributes = {")
a("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
a("\t\t\t\tLastUpgradeCheck = 1600;")
a("\t\t\t\tTargetAttributes = {")
a(f"\t\t\t\t\t{APP_TARGET} = {{")
a("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
a("\t\t\t\t\t};")
a(f"\t\t\t\t\t{TEST_TARGET} = {{")
a("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
a(f"\t\t\t\t\t\tTestTargetID = {APP_TARGET};")
a("\t\t\t\t\t};")
a("\t\t\t\t};")
a("\t\t\t};")
a(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_PROJECT} /* Build configuration list for PBXProject \"FuentesArchive\" */;")
a("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
a("\t\t\tdevelopmentRegion = en;")
a("\t\t\thasScannedForEncodings = 0;")
a("\t\t\tknownRegions = (")
a("\t\t\t\ten,")
a("\t\t\t\tBase,")
a("\t\t\t);")
a(f"\t\t\tmainGroup = {GROUP_MAIN};")
a(f"\t\t\tproductRefGroup = {GROUP_PRODUCTS} /* Products */;")
a("\t\t\tprojectDirPath = \"\";")
a("\t\t\tprojectRoot = \"\";")
a("\t\t\ttargets = (")
a(f"\t\t\t\t{APP_TARGET} /* FuentesArchive */,")
a(f"\t\t\t\t{TEST_TARGET} /* FuentesArchiveTests */,")
a("\t\t\t);")
a("\t\t};")
a("/* End PBXProject section */")
a("")
a("/* Begin PBXResourcesBuildPhase section */")
a(f"\t\t{APP_RESOURCES_PHASE} /* Resources */ = {{")
a("\t\t\tisa = PBXResourcesBuildPhase;")
a("\t\t\tbuildActionMask = 2147483647;")
a("\t\t\tfiles = (")
for path in APP_RESOURCES:
    a(f"\t\t\t\t{build_file(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
a("\t\t};")
a(f"\t\t{TEST_RESOURCES_PHASE} /* Resources */ = {{")
a("\t\t\tisa = PBXResourcesBuildPhase;")
a("\t\t\tbuildActionMask = 2147483647;")
a("\t\t\tfiles = (")
for path in TEST_RESOURCES:
    a(f"\t\t\t\t{build_file(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
a("\t\t};")
a("/* End PBXResourcesBuildPhase section */")
a("")
a("/* Begin PBXSourcesBuildPhase section */")
a(f"\t\t{APP_SOURCES_PHASE} /* Sources */ = {{")
a("\t\t\tisa = PBXSourcesBuildPhase;")
a("\t\t\tbuildActionMask = 2147483647;")
a("\t\t\tfiles = (")
for path in APP:
    a(f"\t\t\t\t{build_file(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
a("\t\t};")
a(f"\t\t{TEST_SOURCES_PHASE} /* Sources */ = {{")
a("\t\t\tisa = PBXSourcesBuildPhase;")
a("\t\t\tbuildActionMask = 2147483647;")
a("\t\t\tfiles = (")
for path in TEST_SOURCES:
    a(f"\t\t\t\t{build_file(path)} /* {Path(path).name} */,")
a("\t\t\t);")
a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
a("\t\t};")
a("/* End PBXSourcesBuildPhase section */")
a("")
a("/* Begin PBXTargetDependency section */")
a(f"\t\t{DEPENDENCY} /* PBXTargetDependency */ = {{")
a("\t\t\tisa = PBXTargetDependency;")
a(f"\t\t\ttarget = {APP_TARGET} /* FuentesArchive */;")
a(f"\t\t\ttargetProxy = {PROXY} /* PBXContainerItemProxy */;")
a("\t\t};")
a("/* End PBXTargetDependency section */")
a("")


def config(debug: bool, kind: str) -> str:
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    if debug:
        common.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        })
    else:
        common.update({
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
            "VALIDATE_PRODUCT": "NO",
        })
    if kind == "app":
        common.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": '""',
            "CURRENT_PROJECT_VERSION": "4",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "FuentesArchive/Info.plist",
            "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
            "LD_RUNPATH_SEARCH_PATHS": '"( $(inherited), @executable_path/Frameworks )"'.replace(" ", ""),
            "MARKETING_VERSION": "1.3.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.local.fuentesarchive",
            "PRODUCT_NAME": "FuentesArchive",
            "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
            "SUPPORTS_MACCATALYST": "NO",
            "SWIFT_STRICT_CONCURRENCY": "minimal",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
        })
        # fix the botched runpath
        common["LD_RUNPATH_SEARCH_PATHS"] = '"( $(inherited), @executable_path/Frameworks )"'
    elif kind == "test":
        common.update({
            "BUNDLE_LOADER": '"$(TEST_HOST)"',
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": '""',
            "GENERATE_INFOPLIST_FILE": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.local.fuentesarchive.tests",
            "PRODUCT_NAME": "FuentesArchiveTests",
            "SDKROOT": "iphoneos",
            "SWIFT_STRICT_CONCURRENCY": "minimal",
            "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/FuentesArchive.app/FuentesArchive"',
        })
    body = ["\t\t\tisa = XCBuildConfiguration;", f"\t\t\tbuildSettings = {{"]
    for key in sorted(common):
        body.append(f"\t\t\t\t{key} = {common[key]};")
    body.append("\t\t\t};")
    body.append(f"\t\t\tname = {'Debug' if debug else 'Release'};")
    return "\n".join(body)


a("/* Begin XCBuildConfiguration section */")
for ident, debug, kind in (
    (CFG_PROJECT_DEBUG, True, "project"),
    (CFG_PROJECT_RELEASE, False, "project"),
    (CFG_APP_DEBUG, True, "app"),
    (CFG_APP_RELEASE, False, "app"),
    (CFG_TEST_DEBUG, True, "test"),
    (CFG_TEST_RELEASE, False, "test"),
):
    a(f"\t\t{ident} /* {'Debug' if debug else 'Release'} */ = {{")
    a(config(debug, kind))
    a("\t\t};")
a("/* End XCBuildConfiguration section */")
a("")
a("/* Begin XCConfigurationList section */")
for ident, debug_id, release_id, comment in (
    (CONFIG_LIST_PROJECT, CFG_PROJECT_DEBUG, CFG_PROJECT_RELEASE, "PBXProject \"FuentesArchive\""),
    (CONFIG_LIST_APP, CFG_APP_DEBUG, CFG_APP_RELEASE, "PBXNativeTarget \"FuentesArchive\""),
    (CONFIG_LIST_TEST, CFG_TEST_DEBUG, CFG_TEST_RELEASE, "PBXNativeTarget \"FuentesArchiveTests\""),
):
    a(f"\t\t{ident} /* Build configuration list for {comment} */ = {{")
    a("\t\t\tisa = XCConfigurationList;")
    a("\t\t\tbuildConfigurations = (")
    a(f"\t\t\t\t{debug_id} /* Debug */,")
    a(f"\t\t\t\t{release_id} /* Release */,")
    a("\t\t\t);")
    a("\t\t\tdefaultConfigurationIsVisible = 0;")
    a("\t\t\tdefaultConfigurationName = Release;")
    a("\t\t};")
a("/* End XCConfigurationList section */")
a("\t};")
a(f"\trootObject = {PROJECT} /* Project object */;")
a("}")

project_dir = ROOT / "FuentesArchive.xcodeproj"
project_dir.mkdir(exist_ok=True)
(project_dir / "project.pbxproj").write_text("\n".join(lines) + "\n", encoding="utf-8")

scheme_dir = project_dir / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{APP_TARGET}"
               BuildableName = "FuentesArchive.app"
               BlueprintName = "FuentesArchive"
               ReferencedContainer = "container:FuentesArchive.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TEST_TARGET}"
               BuildableName = "FuentesArchiveTests.xctest"
               BlueprintName = "FuentesArchiveTests"
               ReferencedContainer = "container:FuentesArchive.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET}"
            BuildableName = "FuentesArchive.app"
            BlueprintName = "FuentesArchive"
            ReferencedContainer = "container:FuentesArchive.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET}"
            BuildableName = "FuentesArchive.app"
            BlueprintName = "FuentesArchive"
            ReferencedContainer = "container:FuentesArchive.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
(scheme_dir / "FuentesArchive.xcscheme").write_text(scheme, encoding="utf-8")
print(f"Wrote project. App target {APP_TARGET}. Test target {TEST_TARGET}.")
print(f"Test fixtures: {len(TEST_RESOURCES)}")
