package com.example.indoor_nav

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startRawBleScanForDiagnostics()
    }

    // TEMPORARY DIAGNOSTIC — bypasses flutter_reactive_ble and RxAndroidBle
    // entirely, using Android's BluetoothLeScanner directly, to check
    // whether the OS itself receives a specific beacon's advertisement at
    // all. If a device that shows up in nRF Connect never appears here
    // either (tag "RAWBLE" in logcat), the issue is below the app layer.
    // Remove this override once the underlying detection issue is resolved.
    private fun startRawBleScanForDiagnostics() {
        val scanPermission =
            if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_SCAN else Manifest.permission.ACCESS_FINE_LOCATION
        val hasScanPermission = checkSelfPermission(scanPermission) == PackageManager.PERMISSION_GRANTED
        if (!hasScanPermission) {
            Log.w("RAWBLE", "Scan permission not granted yet, skipping raw diagnostic scan")
            return
        }

        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter? = bluetoothManager.adapter
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            Log.w("RAWBLE", "No BluetoothLeScanner available (adapter off or unsupported)")
            return
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val bytes = result.scanRecord?.bytes
                val hex = bytes?.joinToString(" ") { String.format("%02x", it) } ?: "null"
                val connectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    result.isConnectable
                } else {
                    false
                }
                Log.i(
                    "RAWBLE",
                    "id=${result.device.address} rssi=${result.rssi} connectable=$connectable rawBytes=$hex",
                )
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e("RAWBLE", "Raw scan failed, errorCode=$errorCode")
            }
        }

        try {
            scanner.startScan(null, settings, callback)
            Log.i("RAWBLE", "Raw diagnostic BLE scan started")
        } catch (e: SecurityException) {
            Log.e("RAWBLE", "SecurityException starting raw scan: ${e.message}")
        }
    }
}
