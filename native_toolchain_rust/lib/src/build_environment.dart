import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:meta/meta.dart';
import 'package:native_toolchain_rust/src/config_mapping.dart';
import 'package:native_toolchain_rust/src/exception.dart';
import 'package:path/path.dart' as path;

@internal
interface class BuildEnvironmentFactory {
  const BuildEnvironmentFactory();

  Map<String, String> createBuildEnvVars(CodeConfig codeConfig) {
    return {
      // NOTE: XCode makes some injections into PATH that break host build
      // for crates with a build.rs
      // See also: https://github.com/irondash/native_toolchain_rust/issues/17
      if (Platform.isMacOS) ...{
        'PATH': Platform.environment['PATH']!
            .split(':')
            .where((e) => !e.contains('Contents/Developer/'))
            .join(':'),
      },

      if (codeConfig.targetOS == OS.android)
        ...const AndroidBuildEnvironmentFactory().createBuildEnvVars(
          codeConfig: codeConfig,
        ),
    };
  }
}

@internal
interface class AndroidBuildEnvironmentFactory {
  const AndroidBuildEnvironmentFactory();

  Map<String, String> createBuildEnvVars({required CodeConfig codeConfig}) {
    final CodeConfig(:targetTriple, :cCompiler) = codeConfig;
    if (cCompiler == null) {
      throw UnsupportedError(
        'CCompilerConfig was not provided but is required for $targetTriple',
      );
    }

    String rawBinaryPath(String binaryName, {String windowsSuffix = 'cmd'}) {
      final compilerBinariesDir = path.dirname(
        path.fromUri(cCompiler.compiler),
      );
      return path.join(
        compilerBinariesDir,
        (OS.current == OS.windows) ? '$binaryName.$windowsSuffix' : binaryName,
      );
    }

    String getBinaryPath(String binaryName, {String windowsSuffix = 'cmd'}) {
      final binaryPath = rawBinaryPath(
        binaryName,
        windowsSuffix: windowsSuffix,
      );

      if (!File(binaryPath).existsSync()) {
        throw RustValidationException([
          'Binary $binaryPath not found; is your installed NDK too old?',
        ]);
      }

      return binaryPath;
    }

    final targetTripleEnvVar = targetTriple.replaceAll('-', '_');
    final ndkTargetTriple = switch (targetTriple) {
      // NOTE: sometimes the Rust and NDK target triples do not match.
      // See: https://github.com/GregoryConrad/native_toolchain_rust/issues/21#issuecomment-3368307228
      'armv7-linux-androideabi' => 'armv7a-linux-androideabi',
      _ => targetTriple,
    };
    final ndkSysrootTargetTriple = switch (targetTriple) {
      // NOTE: sometimes the Rust and NDK sysroot target triples do not match.
      'armv7-linux-androideabi' => 'arm-linux-androideabi',
      _ => targetTriple,
    };

    // 用哪个 API 级别的 clang 驱动：Flutter 给出的就是应用的 minSdk
    // （flutter_tools 的 targetAndroidNdkApi 读的是 minSdkVersion define），
    // 也就是"这个库要在多老的系统上跑"。
    //
    // 上游在这里写死 35，而驱动级别同时决定两件事：
    // 1. 取哪一套系统库桩文件（libc、liblog 等）。按 35 编译时库里可以用上高版本
    //    才有的符号，链接期不报错，装到 minSdk 的旧设备上却会因为
    //    `cannot locate symbol` 加载失败；
    // 2. lld 往动态表里写什么（见下面的 RELR 说明），以及链接结果的 API 级别标记。
    //
    // 所以按 minSdk 选驱动，产物才和声明的最低版本一致。NDK 只提供一段范围的
    // clang 驱动（NDK r29 是 21~35），取不到时退到最接近的可用值。
    final wantNdkApi = codeConfig.android.targetNdkApi;
    var driverApi = wantNdkApi;
    while (driverApi > 1 &&
        !File(rawBinaryPath('$ndkTargetTriple$driverApi-clang')).existsSync()) {
      driverApi--;
    }
    if (driverApi <= 1) {
      // 连最老的驱动都找不到：保持上游行为（下面的 getBinaryPath 会给出
      // "is your installed NDK too old?" 的提示）
      driverApi = wantNdkApi;
    } else if (driverApi != wantNdkApi) {
      // 只在 NDK 支持范围与应用 minSdk 不一致时出现，日志里留一行
      stderr.writeln(
        'native_toolchain_rust: NDK 没有 $ndkTargetTriple$wantNdkApi-clang，'
        '改用 $ndkTargetTriple$driverApi-clang（应用 minSdk=$wantNdkApi）',
      );
    }

    final clangPath = getBinaryPath('$ndkTargetTriple$driverApi-clang');
    final clangPpPath = getBinaryPath('$ndkTargetTriple$driverApi-clang++');
    final ranlibPath = getBinaryPath('llvm-ranlib', windowsSuffix: 'exe');

    final ndkToolchainRoot = path.dirname(path.dirname(clangPath));
    final sysroot = path.join(ndkToolchainRoot, 'sysroot');
    final extraInclude = '$sysroot/usr/include/$ndkSysrootTargetTriple';
    final bindgenClangArgs = '--sysroot=$sysroot -I$extraInclude'
        // NOTE: force the use of forward-slash path separators
        .replaceAll(r'\', '/');

    // 关掉加载器不认识的相对重定位压缩（RELR）。
    //
    // lld 会按目标 API 级别决定链接结果的动态表项：API 28 起把相对重定位写进
    // ANDROID_RELR / ANDROID_RELRSZ / ANDROID_RELRENT（0x6fffe000 ~ 0x6fffe003），
    // 而 Android 11（API 30）之前的动态加载器不认识这几项（只会打印
    // `unused DT entry: type 0x6fffe000` 然后照常加载）。此时 .so 里指向自身数据的
    // 指针仍停留在链接期地址，脚本的解引用会跳到那个地址 —— 表现为旧系统上
    // 进程刚启动就 SIGSEGV（pc 与 fault addr 相同）。
    //
    // 这里显式改回所有版本都支持的 RELA 表项。注意只有 lld 的
    // `--pack-dyn-relocs=none` 有效：ELF 的 `-z nopack-relative-relocs` 写法在
    // Android 目标上不会关掉 RELR。
    const noRelr = '-C link-arg=-Wl,--pack-dyn-relocs=none';

    return {
      'AR_$targetTripleEnvVar': path.fromUri(cCompiler.archiver),
      'CC_$targetTripleEnvVar': clangPath,
      'CXX_$targetTripleEnvVar': clangPpPath,
      'RANLIB_$targetTripleEnvVar': ranlibPath,
      'CARGO_TARGET_${targetTripleEnvVar.toUpperCase()}_LINKER': clangPath,
      'CARGO_TARGET_${targetTripleEnvVar.toUpperCase()}_RUSTFLAGS': noRelr,
      'BINDGEN_EXTRA_CLANG_ARGS_$targetTripleEnvVar': bindgenClangArgs,
    };
  }
}
