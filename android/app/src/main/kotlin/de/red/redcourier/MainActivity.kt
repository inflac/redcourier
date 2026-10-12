package de.red.redcourier

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands verified updates to Android's package installer. The Dart side
 * downloads the APK through Tor and checks its release signature first;
 * Android then checks that the APK is signed with the same key as the
 * installed app and asks the user to confirm.
 */
class MainActivity : FlutterActivity() {
    private val statusAction = "de.red.redcourier.INSTALL_STATUS"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "redcourier/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "installerPackage" -> result.success(installerPackage())
                        "canInstall" -> result.success(
                            Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()
                        )
                        "openInstallSettings" -> {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(null)
                        }
                        "installApk" -> {
                            installApk(File(call.argument<String>("path")!!))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("update", e.message, null)
                }
            }
    }

    /** Which app installed RedCourier (null for adb). */
    private fun installerPackage(): String? =
        if (Build.VERSION.SDK_INT >= 30) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstallerPackageName(packageName)
        }

    private fun installApk(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("update.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            // Android reports back to this activity (onNewIntent), usually
            // asking to show its confirmation screen.
            val intent = Intent(this, MainActivity::class.java).setAction(statusAction)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
            session.commit(PendingIntent.getActivity(this, id, intent, flags).intentSender)
        }
        apk.delete()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != statusAction) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            if (confirm != null) startActivity(confirm)
        }
    }
}
