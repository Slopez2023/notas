#!/usr/bin/env python3
"""Generate the three native targets from the same Swift sources used by SwiftPM."""
import argparse
import hashlib
import pathlib
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]


def identifier(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def encode(value, level=0):
    pad = '\t' * level
    if isinstance(value, dict):
        lines = ['{']
        lines += ['\t' * (level + 1) + encode(str(key)) + ' = ' + encode(item, level + 1) + ';' for key, item in value.items()]
        return '\n'.join(lines + [pad + '}'])
    if isinstance(value, list):
        return '(' + ', '.join(encode(item, level + 1) for item in value) + (',' if value else '') + ')'
    if isinstance(value, int):
        return str(value)
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def generate(team):
    objects = {}

    def add(key, isa, **properties):
        oid = identifier(key)
        objects[oid] = {'isa': isa, **properties}
        return oid

    file_refs = {}

    def file(path, filetype=None):
        if path not in file_refs:
            kind = filetype or ('sourcecode.swift' if path.endswith('.swift') else 'text.plist.xml')
            file_refs[path] = add('file:' + path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='SOURCE_ROOT')
        return file_refs[path]

    shared = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/NotasShared').glob('*.swift'))
    app_sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/Notas').rglob('*.swift'))
    definitions = [
        ('Notas', 'com.stephenlopez.notas', app_sources + shared, 'Resources/Info.plist', 'Resources/Notas.entitlements', 'com.apple.product-type.application'),
        ('NotasShare', 'com.stephenlopez.notas.NotasShare', shared + ['Extensions/NotasShare/ShareViewController.swift'], 'Extensions/NotasShare/Info.plist', 'Extensions/NotasShare/NotasShare.entitlements', 'com.apple.product-type.app-extension'),
        ('NotasWidgets', 'com.stephenlopez.notas.NotasWidgets', shared + ['Extensions/NotasWidgets/NotasWidgets.swift'], 'Extensions/NotasWidgets/Info.plist', 'Extensions/NotasWidgets/NotasWidgets.entitlements', 'com.apple.product-type.app-extension'),
    ]
    targets = []
    products = []
    target_ids = {name: identifier('target:' + name) for name, *_ in definitions}
    project_id = identifier('project')
    for name, bundle, sources, info, entitlement, product_type in definitions:
        extension = '.app' if name == 'Notas' else '.appex'
        product = add('product:' + name, 'PBXFileReference', explicitFileType='wrapper.application' if name == 'Notas' else 'wrapper.app-extension', includeInIndex=0, path=name + extension, sourceTree='BUILT_PRODUCTS_DIR')
        products.append(product)
        files = [add('build:' + name + ':' + path, 'PBXBuildFile', fileRef=file(path)) for path in sources]
        source_phase = add('sources:' + name, 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)
        frameworks = add('frameworks:' + name, 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
        resources = []
        if name == 'Notas':
            for path, kind in [('Resources/Fonts', 'folder'), ('Resources/AppIcon.icns', 'image.icns'), ('scripts/install-update.sh', 'text.script.sh')]:
                resources.append(add('resource-build:' + path, 'PBXBuildFile', fileRef=file(path, kind)))
        resource_phase = add('resources:' + name, 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
        phases = [source_phase, frameworks, resource_phase]
        dependencies = []
        if name == 'Notas':
            embed_files = []
            for child in ['NotasShare', 'NotasWidgets']:
                child_product = identifier('product:' + child)
                embed_files.append(add('embed:' + child, 'PBXBuildFile', fileRef=child_product, settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']}))
                proxy = add('proxy:' + child, 'PBXContainerItemProxy', containerPortal=project_id, proxyType=1, remoteGlobalIDString=target_ids[child], remoteInfo=child)
                dependencies.append(add('dependency:' + child, 'PBXTargetDependency', target=target_ids[child], targetProxy=proxy))
            phases.append(add('embed-phase', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=embed_files, name='Embed App Extensions', runOnlyForDeploymentPostprocessing=0))
        configurations = []
        for configuration in ['Debug', 'Release']:
            settings = {
                'PRODUCT_NAME': name, 'PRODUCT_BUNDLE_IDENTIFIER': bundle, 'PRODUCT_MODULE_NAME': name,
                'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '26.0', 'ARCHS': 'arm64', 'SWIFT_VERSION': '5.0',
                'INFOPLIST_FILE': info, 'GENERATE_INFOPLIST_FILE': 'NO', 'CODE_SIGN_ENTITLEMENTS': entitlement,
                'CODE_SIGN_STYLE': 'Automatic', 'DEVELOPMENT_TEAM': team, 'ENABLE_HARDENED_RUNTIME': 'YES',
                'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if configuration == 'Debug' else '-O',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if configuration == 'Debug' else '',
                'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks'],
            }
            if name != 'Notas':
                settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
                settings['SKIP_INSTALL'] = 'YES'
            if name == 'NotasShare':
                settings['OTHER_LDFLAGS'] = ['$(inherited)', '-e', '_NSExtensionMain']
            configurations.append(add('config:' + name + configuration, 'XCBuildConfiguration', buildSettings=settings, name=configuration))
        config_list = add('configs:' + name, 'XCConfigurationList', buildConfigurations=configurations, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
        targets.append(add('target:' + name, 'PBXNativeTarget', buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=product, productType=product_type))
        file(info); file(entitlement)
    products_group = add('products-group', 'PBXGroup', children=products, name='Products', sourceTree='<group>')
    sources_group = add('sources-group', 'PBXGroup', children=list(file_refs.values()), name='Sources and resources', sourceTree='<group>')
    main_group = add('main-group', 'PBXGroup', children=[sources_group, products_group], sourceTree='<group>')
    project_configs = [add('project-config:' + name, 'XCBuildConfiguration', buildSettings={}, name=name) for name in ['Debug', 'Release']]
    project_config_list = add('project-configs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
    add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2710', 'TargetAttributes': {oid: {'CreatedOnToolsVersion': '27.0', 'ProvisioningStyle': 'Automatic'} for oid in targets}}, buildConfigurationList=project_config_list, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=main_group, productRefGroup=products_group, projectDirPath='', projectRoot='', targets=targets)
    project = ROOT / 'Notas.xcodeproj'
    project.mkdir(exist_ok=True)
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode({'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': project_id}) + '\n')
    scheme = ET.Element('Scheme', {'LastUpgradeVersion': '2710', 'version': '1.3'})
    action = ET.SubElement(scheme, 'BuildAction', {'parallelizeBuildables': 'YES', 'buildImplicitDependencies': 'YES'})
    entries = ET.SubElement(action, 'BuildActionEntries')
    entry = ET.SubElement(entries, 'BuildActionEntry', {key: 'YES' for key in ['buildForTesting', 'buildForRunning', 'buildForProfiling', 'buildForArchiving', 'buildForAnalyzing']})
    reference = {'BuildableIdentifier': 'primary', 'BlueprintIdentifier': target_ids['Notas'], 'BuildableName': 'Notas.app', 'BlueprintName': 'Notas', 'ReferencedContainer': 'container:Notas.xcodeproj'}
    ET.SubElement(entry, 'BuildableReference', reference)
    launch = ET.SubElement(scheme, 'LaunchAction', {'buildConfiguration': 'Debug', 'selectedDebuggerIdentifier': 'Xcode.DebuggerFoundation.Debugger.LLDB', 'selectedLauncherIdentifier': 'Xcode.IDEFoundation.Launcher.LLDB', 'launchStyle': '0', 'useCustomWorkingDirectory': 'NO', 'ignoresPersistentStateOnLaunch': 'NO', 'debugDocumentVersioning': 'YES', 'allowLocationSimulation': 'YES'})
    runnable = ET.SubElement(launch, 'BuildableProductRunnable', {'runnableDebuggingMode': '0'})
    ET.SubElement(runnable, 'BuildableReference', reference)
    ET.SubElement(scheme, 'AnalyzeAction', {'buildConfiguration': 'Debug'})
    ET.SubElement(scheme, 'ArchiveAction', {'buildConfiguration': 'Release', 'revealArchiveInOrganizer': 'YES'})
    scheme_path = project / 'xcshareddata/xcschemes/Notas.xcscheme'
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(scheme_path, encoding='UTF-8', xml_declaration=True)
    print(project)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--team', default='')
    generate(parser.parse_args().team)
