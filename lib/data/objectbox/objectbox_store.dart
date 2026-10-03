import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:path_provider/path_provider.dart';

/// The App Group ObjectBox uses for inter-process communication.
///
/// **A sandboxed macOS app cannot open a store without one.** ObjectBox's
/// mutexes use POSIX semaphores, and a sandboxed app may only use those for IPC
/// through an App Group. Without this the store fails to open with:
///
/// ```
/// StorageException: failed to create store: Could not open database
/// environment; please check options and file system
/// (1: Operation not permitted) (OBX_ERROR code 10199)
/// ```
///
/// Note the failure mode: it is **not** "permission denied on your data
/// directory". The directory is writable; the semaphore namespace is not.
///
/// **macOS limits the whole string to 19 characters**, and the limit applies to
/// the value passed here, not to the group id alone. `group.mln.lnb` is 12.
///
/// Passed unconditionally rather than behind a `Platform.isMacOS` branch: the
/// parameter is documented as macOS-only and is inert elsewhere, so gating it
/// would add a platform conditional for no behavioural difference (spec NFR1,
/// AC23).
///
/// The group must also be registered in Xcode (Runner → Signing & Capabilities
/// → App Groups) for a signed build.
const String macosApplicationGroup = 'group.mln.lnb';

/// Opens the production store in the platform's application-support directory.
///
/// Platform-agnostic by construction: `path_provider` resolves the directory
/// per platform and nothing here branches on `Platform.is*` (spec NFR1, NFR2,
/// AC23).
///
/// **A production store must be opened exactly once.** ObjectBox refuses to
/// open the same directory twice, and Flutter hot restart re-runs `main()` —
/// so the caller must not call this on every rebuild. `bootstrap.dart` opens it
/// once and hands it down as a constructor argument.
Future<Store> openLibraryStore() async => openStore(
      directory: (await getApplicationSupportDirectory()).path,
      macosApplicationGroup: macosApplicationGroup,
    );

/// Opens a file-less, in-memory store for tests (spec NFR4, plan §F).
///
/// The timestamp in the directory name is **not optional**. `Store.inMemoryPrefix`
/// alone resolves to the same in-memory database for every call in an isolate,
/// so state leaks between tests and failures become order-dependent — the worst
/// possible failure mode in a suite.
Store openTestStore([String tag = 'test']) => Store(
      getObjectBoxModel(),
      directory: '${Store.inMemoryPrefix}lib-$tag-'
          '${DateTime.now().microsecondsSinceEpoch}',
    );
