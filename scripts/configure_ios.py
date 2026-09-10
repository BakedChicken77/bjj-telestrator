"""Wire app-owned Swift files and simulator tests into the Capacitor Xcode project.

Idempotent; uses only Python's standard library. Run after adding a native Swift file.
"""

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "frontend/ios/App/App.xcodeproj/project.pbxproj"
APP = "504EC3031FED79650016851F"
APP_GROUP = "504EC3061FED79650016851F"
PRODUCTS = "504EC3051FED79650016851F"
MAIN_GROUP = "504EC2FB1FED79650016851F"
PROJECT_ID = "504EC2FC1FED79650016851F"
SOURCES = "504EC3001FED79650016851F"
RESOURCES = "504EC3021FED79650016851F"


def uid(label: str) -> str:
    return hashlib.sha256(("bjj-ios:" + label).encode()).hexdigest()[:24].upper()


def main() -> None:
    text = PROJECT.read_text()

    def section(name: str, identifier: str, body: str) -> None:
        nonlocal text
        if f"{identifier} = " in text or f"{identifier} /* BJJ */ = " in text:
            return
        end = f"/* End {name} section */"
        if end not in text:
            before = "\n/* Begin PBXProject section */"
            text = text.replace(before, f"\n/* Begin {name} section */\n{end}\n" + before)
        text = text.replace(end, f"\t\t{identifier} = {{{body}}};\n{end}")

    def child(parent: str, field: str, identifier: str) -> None:
        nonlocal text
        start = text.index(parent)
        # Find the object's definition, not an earlier reference.
        import re

        match = re.search(re.escape(parent) + r"(?: /\*.*?\*/)? = \{", text)
        if not match:
            raise RuntimeError(f"Missing Xcode object {parent}")
        start = text.index(field + " = (", match.start()) + len(field + " = (")
        end = text.index(");", start)
        if identifier not in text[start:end]:
            text = text[:start] + f"\n\t\t\t\t{identifier}," + text[start:]

    for path in sorted((ROOT / "frontend/ios/App/App/Native").glob("*.swift")):
        ref, build = uid("file:" + path.name), uid("build:" + path.name)
        section(
            "PBXFileReference",
            ref,
            f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Native/{path.name}"; sourceTree = "<group>";',
        )
        section("PBXBuildFile", build, f"isa = PBXBuildFile; fileRef = {ref};")
        child(APP_GROUP, "children", ref)
        child(SOURCES, "files", build)
    privacy, privacy_build = uid("privacy"), uid("privacy-build")
    section(
        "PBXFileReference",
        privacy,
        'isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>";',
    )
    section("PBXBuildFile", privacy_build, f"isa = PBXBuildFile; fileRef = {privacy};")
    child(APP_GROUP, "children", privacy)
    child(RESOURCES, "files", privacy_build)

    (
        target,
        group,
        product,
        ref,
        build,
        config_list,
        debug,
        release,
        sources,
        frameworks,
        resources,
        proxy,
        dependency,
    ) = [
        uid("test:" + key)
        for key in [
            "target",
            "group",
            "product",
            "file",
            "build",
            "config-list",
            "debug",
            "release",
            "sources",
            "frameworks",
            "resources",
            "proxy",
            "dependency",
        ]
    ]
    section(
        "PBXFileReference",
        ref,
        'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BJJNativeTests.swift; sourceTree = "<group>";',
    )
    section(
        "PBXFileReference",
        product,
        "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;",
    )
    section(
        "PBXGroup", group, f'isa = PBXGroup; children = ({ref},); path = AppTests; sourceTree = "<group>";'
    )
    section("PBXBuildFile", build, f"isa = PBXBuildFile; fileRef = {ref};")
    for name, phase, files in [
        ("PBXSourcesBuildPhase", sources, build + ","),
        ("PBXFrameworksBuildPhase", frameworks, ""),
        ("PBXResourcesBuildPhase", resources, ""),
    ]:
        section(
            name,
            phase,
            f"isa = {name}; buildActionMask = 2147483647; files = ({files}); runOnlyForDeploymentPostprocessing = 0;",
        )
    section(
        "PBXContainerItemProxy",
        proxy,
        f"isa = PBXContainerItemProxy; containerPortal = {PROJECT_ID}; proxyType = 1; remoteGlobalIDString = {APP}; remoteInfo = App;",
    )
    section(
        "PBXTargetDependency",
        dependency,
        f"isa = PBXTargetDependency; target = {APP}; targetProxy = {proxy};",
    )
    for identifier, name in [(debug, "Debug"), (release, "Release")]:
        settings = 'BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/App.app/App"; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = com.bjjtelestrator.app.tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;'
        section(
            "XCBuildConfiguration",
            identifier,
            f"isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name};",
        )
    section(
        "XCConfigurationList",
        config_list,
        f"isa = XCConfigurationList; buildConfigurations = ({debug}, {release},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
    )
    section(
        "PBXNativeTarget",
        target,
        f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({sources}, {frameworks}, {resources},); buildRules = (); dependencies = ({dependency},); name = AppTests; productName = AppTests; productReference = {product}; productType = "com.apple.product-type.bundle.unit-test";',
    )
    child(MAIN_GROUP, "children", group)
    child(PRODUCTS, "children", product)
    child(PROJECT_ID, "targets", target)
    PROJECT.write_text(text)
    scheme = PROJECT.parent / "xcshareddata/xcschemes/App.xcscheme"
    scheme.parent.mkdir(parents=True, exist_ok=True)

    def reference(identifier: str, name: str, product_name: str) -> str:
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier}" BuildableName="{product_name}" BlueprintName="{name}" ReferencedContainer="container:App.xcodeproj"/>'

    app_ref, test_ref = reference(APP, "App", "App.app"), reference(target, "AppTests", "AppTests.xctest")
    scheme.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
    print("Native sources, privacy manifest, and AppTests scheme are wired into Xcode.")


if __name__ == "__main__":
    main()
