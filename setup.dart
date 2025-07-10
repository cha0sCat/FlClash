// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart';
import 'package:charset/charset.dart';

enum TargetPlatform {
  windows,
  linux,
  android,
  macos,
}

extension TargetPlatformExt on TargetPlatform {
  String get os => this == TargetPlatform.macos ? "darwin" : name;

  bool get isCurrentPlatform =>
      (this == TargetPlatform.android) ||
          (Platform.isWindows && this == TargetPlatform.windows) ||
          (Platform.isLinux && this == TargetPlatform.linux) ||
          (Platform.isMacOS && this == TargetPlatform.macos);

  String get dynamicLibExtensionName {
    switch (this) {
      case TargetPlatform.android:
      case TargetPlatform.linux:
        return ".so";
      case TargetPlatform.windows:
        return ".dll";
      case TargetPlatform.macos:
        return ".dylib";
    }
  }

  String get executableExtensionName => this == TargetPlatform.windows ? ".exe" : "";
}

enum Mode { core, lib }

enum Arch { amd64, arm64, arm }

class BuildTarget {
  final TargetPlatform platform;
  final Arch? arch;
  final String? archName;

  BuildTarget({
    required this.platform,
    this.arch,
    this.archName,
  });

  @override
  String toString() =>
      'BuildTarget{target: $platform, arch: $arch, archName: $archName}';
}

class Build {
  static const String appName = "FlClash";
  static const String coreName = "FlClashCore";
  static const String libName = "libclash";
  static final String outDir = join(current, libName);
  static final String _coreDir = join(current, "core");
  static final String _servicesDir = join(current, "services", "helper");
  static final String distPath = join(current, "dist");

  static List<BuildTarget> get allBuildTargets => [
    BuildTarget(platform: TargetPlatform.macos, arch: Arch.arm64),
    BuildTarget(platform: TargetPlatform.macos, arch: Arch.amd64),
    BuildTarget(platform: TargetPlatform.linux, arch: Arch.arm64),
    BuildTarget(platform: TargetPlatform.linux, arch: Arch.amd64),
    BuildTarget(platform: TargetPlatform.windows, arch: Arch.amd64),
    BuildTarget(platform: TargetPlatform.windows, arch: Arch.arm64),
    BuildTarget(platform: TargetPlatform.android, arch: Arch.arm, archName: 'armeabi-v7a'),
    BuildTarget(platform: TargetPlatform.android, arch: Arch.arm64, archName: 'arm64-v8a'),
    BuildTarget(platform: TargetPlatform.android, arch: Arch.amd64, archName: 'x86_64'),
  ];

  static String _getCc(BuildTarget buildItem) {
    if (buildItem.platform == TargetPlatform.android) {
      final ndk = Platform.environment["ANDROID_NDK"];
      if (ndk == null) {
        throw ArgumentError("ANDROID_NDK environment variable is not set");
      }
      final prebuiltDir = Directory(join(ndk, "toolchains", "llvm", "prebuilt"));
      final prebuiltDirList = prebuiltDir.listSync();
      final map = {
        "armeabi-v7a": "armv7a-linux-androideabi21-clang",
        "arm64-v8a": "aarch64-linux-android21-clang",
        "x86": "i686-linux-android21-clang",
        "x86_64": "x86_64-linux-android21-clang"
      };
      return join(prebuiltDirList.first.path, "bin", map[buildItem.archName]!);
    }
    return "gcc";
  }

  /// 解码并打印流数据，支持多种编码格式（UTF-8, GBK 等）
  static Future<void> decodeAndPrint(Stream<List<int>> stream) async {
    final buffer = <int>[];

    await for (final data in stream) {
      buffer.addAll(data);

      // 尝试以UTF-8解码
      try {
        final decoded = utf8.decode(buffer, allowMalformed: false);
        print(decoded);
        buffer.clear();
      } catch (e) {
        // UTF-8解码失败，尝试其他编码
        try {
          // 针对Windows，尝试GBK编码
          if (Platform.isWindows) {
            final decoded = gbk.decode(buffer);
            print(decoded);
            buffer.clear();
          } else {
            // 如果缓冲区过大但仍无法解码，可能是二进制数据，直接输出
            if (buffer.length > 1024) {
              print("[Binary data or unsupported encoding]");
              buffer.clear();
            }
            // 否则继续收集数据等待更完整的编码
          }
        } catch (e) {
          // 如果缓冲区过大但仍无法解码，清空避免内存溢出
          if (buffer.length > 8192) {
            print("[Unable to decode data with current encoding support]");
            buffer.clear();
          }
        }
      }
    }

    // 处理剩余数据
    if (buffer.isNotEmpty) {
      try {
        final decoded = utf8.decode(buffer, allowMalformed: true);
        print(decoded);
      } catch (e) {
        try {
          if (Platform.isWindows) {
            final decoded = gbk.decode(buffer);
            print(decoded);
          } else {
            print("[Remaining data could not be decoded]");
          }
        } catch (e) {
          print("[Remaining data could not be decoded]");
        }
      }
    }
  }

  static Future<void> exec(
    List<String> command, {
    String? name,
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = true,
  }) async {
    print("Running ${name ?? command}...");
    final process = await Process.start(
      command[0],
      command.sublist(1),
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
    );

    await Future.wait([
      decodeAndPrint(process.stdout),
      decodeAndPrint(process.stderr),
    ]);

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw "Error in $name with exit code $exitCode";
    }
  }

  static Future<void> buildCore({
    required Mode mode,
    required TargetPlatform target,
    Arch? arch,
  }) async {
    final isLib = mode == Mode.lib;
    final buildTargets = allBuildTargets.where(
          (item) => item.platform == target && (arch == null || item.arch == arch),
    );

    for (final buildTarget in buildTargets) {
      final outFileDir = join(outDir, buildTarget.platform.name, buildTarget.archName ?? '');
      final outFile = File(outFileDir);
      if (outFile.existsSync()) {
        outFile.deleteSync(recursive: true);
      }

      final fileName = isLib
          ? "$libName${buildTarget.platform.dynamicLibExtensionName}"
          : "$coreName${buildTarget.platform.executableExtensionName}";
      final outPath = join(outFileDir, fileName);

      final Map<String, String> env = {
        "GOOS": buildTarget.platform.os,
        "CGO_ENABLED": "0",
      };
      if (buildTarget.arch != null) {
        env["GOARCH"] = buildTarget.arch!.name;
      }
      if (isLib) {
        env["CGO_ENABLED"] = "1";
        env["CC"] = _getCc(buildTarget);
        env["CFLAGS"] = "-O3 -Werror";
      }

      final command = [
        "go",
        "build",
        "-ldflags=-w -s",
        "-tags=with_gvisor",
        if (isLib) "-buildmode=c-shared",
        "-o",
        outPath,
      ];

      await exec(command, name: "build core on $buildTarget", environment: env, workingDirectory: _coreDir);
    }
  }

  static Future<void> buildHelper(TargetPlatform target) async {
    await exec(
      ["cargo", "build", "--release", "--features", "windows-service"],
      name: "build helper",
      workingDirectory: _servicesDir,
    );
    final outPath = join(_servicesDir, "target", "release", "helper${target.executableExtensionName}");
    final targetPath = join(outDir, target.name, "FlClashHelperService${target.executableExtensionName}");
    await File(outPath).copy(targetPath);
  }

  static Future<void> getDistributor() async {
    final distributorDir = join(current, "plugins", "flutter_distributor", "packages", "flutter_distributor");

    await exec(
        name: "clean distributor",
        ["flutter", "clean"],
        workingDirectory: distributorDir
    );
    await exec(
        name: "upgrade distributor",
        ["flutter", "pub", "upgrade"],
        workingDirectory: distributorDir
    );
    await exec(
        name: "activate distributor",
        ["dart", "pub", "global", "activate", "-s", "path", distributorDir],
    );
  }

  static void copyFile(String sourcePath, String destinationPath) {
    final source = File(sourcePath);
    if (!source.existsSync()) throw "Source file does not exist: $sourcePath";

    final destination = File(destinationPath);
    destination.parent.createSync(recursive: true);

    try {
      source.copySync(destinationPath);
      print("File copied successfully to $destinationPath");
    } catch (e) {
      print("Failed to copy file: $e");
    }
  }
}

class BuildCommand extends Command {
  final TargetPlatform targetPlatform;

  BuildCommand(this.targetPlatform) {
    argParser.addOption(
      "arch",
      valueHelp: _availableArches.join(","),
      allowed: _availableArches,
      help: "Specify architecture for $name",
    );

    final canCompile = ["core"];
    if (targetPlatform.isCurrentPlatform) {
      canCompile.add("app");
    }
    argParser.addOption(
        "out",
        valueHelp: canCompile.join(","),
        allowed: canCompile,
        help: "Specify output type for $name",

        // app 就包含了 core
        // 如果条件允许，则默认编译 app, 否则只编译 core
        defaultsTo: canCompile.contains("app") ? "app" : "core"
    );
  }

  @override
  String get description => "Build $name application";

  @override
  String get name => targetPlatform.name;

  List<String> get _availableArches => Build.allBuildTargets
      .where((buildTarget) => buildTarget.platform == targetPlatform)
      .map((buildTarget) => buildTarget.arch?.name)
      .nonNulls.toList();

  Future<void> _installLinuxDependencies(Arch arch) async {
    const commands = [
      "sudo apt update -y",
      "sudo apt install -y ninja-build libgtk-3-dev",
      "sudo apt install -y libayatana-appindicator3-dev",
      "sudo apt install -y rpm patchelf",
      "sudo apt-get install -y libkeybinder-3.0-dev",
      "sudo apt install -y locate",
      "sudo apt install -y libfuse2",
    ];

    for (final command in commands) {
      await Build.exec(command.split(" "));
    }

    final downloadName = arch == Arch.amd64 ? "x86_64" : "aarch_64";
    await Build.exec([
      "wget",
      "-O", "appimagetool",
      "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$downloadName.AppImage"
    ]);
    await Build.exec(["chmod", "+x", "appimagetool"]);
    await Build.exec(["sudo", "mv", "appimagetool", "/usr/local/bin/"]);
  }

  Future<void> _installMacosDependencies() async {
    await Build.exec(["npm", "install", "-g", "appdmg"]);
  }

  Future<void> _buildDistributor({required String targets, List<String> extraArgs = const []}) async {
    await Build.getDistributor();
    await Build.exec(
      name: "distributor build",
      [
        "flutter_distributor", "package",
        "--skip-clean",
        "--platform", targetPlatform.name,
        "--targets", targets,
        "--flutter-build-args=verbose",
        ...extraArgs
      ],
    );
  }

  @override
  Future<void> run() async {
    final mode = targetPlatform == TargetPlatform.android ? Mode.lib : Mode.core;
    final out = argResults!["out"];
    final archName = argResults?["arch"];
    final arch = Build.allBuildTargets
        .where((item) => item.platform == targetPlatform && item.arch?.name == archName)
        .map((item) => item.arch!)
        .firstOrNull;

    // 安卓可以直接编译全 arch，其他平台只能编译指定 arch
    if (arch == null && targetPlatform != TargetPlatform.android) {
      throw "Invalid arch parameter";
    }

    await Build.buildCore(target: targetPlatform, arch: arch, mode: mode);

    if (targetPlatform == TargetPlatform.windows) {
      await Build.buildHelper(targetPlatform);
    }

    if (out != "app") return;

    switch (targetPlatform) {
      case TargetPlatform.windows:
        await _buildDistributor(targets: "exe,zip", extraArgs: ["--description", archName]);
        break;
      case TargetPlatform.linux:
        final targetMap = {
          Arch.arm64: "linux-arm64",
          Arch.amd64: "linux-x64",
        };
        await _installLinuxDependencies(arch!);
        await _buildDistributor(targets: "appimage,deb", extraArgs: ["--description", archName, "--build-target-platform", targetMap[arch]!]);
        break;
      case TargetPlatform.android:
        await _buildDistributor(targets: "apk", extraArgs: ["--flutter-build-args", "split-per-abi"]);
        break;
      case TargetPlatform.macos:
        await _installMacosDependencies();
        await _buildDistributor(targets: "dmg", extraArgs: ["--description", archName]);
        break;
    }
  }
}

void main(List<String> args) async {
  final runner = CommandRunner("setup", "Build Application")
    ..addCommand(BuildCommand(TargetPlatform.android))
    ..addCommand(BuildCommand(TargetPlatform.linux))
    ..addCommand(BuildCommand(TargetPlatform.windows))
    ..addCommand(BuildCommand(TargetPlatform.macos));

  await runner.run(args);
}
