package com.maniakprint.rtm_uv_kalibrasi

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "com.maniakprint.rtm_uv_kalibrasi/bt"
        private const val EVENT_CHANNEL = "com.maniakprint.rtm_uv_kalibrasi/bt_rx"
        private const val REQ_BT_PERMS = 4012
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermResult: MethodChannel.Result? = null

    @Volatile
    private var btSocket: BluetoothSocket? = null
    @Volatile
    private var btInput: InputStream? = null
    @Volatile
    private var btOutput: OutputStream? = null
    @Volatile
    private var isReading = false

    private fun getBluetoothAdapter(): BluetoothAdapter? {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val connectOk = ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            val scanOk = ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
            return connectOk && scanOk
        }
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermissions" -> {
                        if (hasBluetoothPermissions()) {
                            result.success(true)
                        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            pendingPermResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.BLUETOOTH_CONNECT,
                                    Manifest.permission.BLUETOOTH_SCAN
                                ),
                                REQ_BT_PERMS
                            )
                        } else {
                            result.success(true)
                        }
                    }

                    "getPairedDevices" -> handleGetPairedDevices(result)

                    "connect" -> {
                        val address = call.argument<String>("address")
                        if (address.isNullOrBlank()) {
                            result.error("INVALID_ARG", "Alamat Bluetooth kosong", null)
                        } else {
                            handleConnect(address, result)
                        }
                    }

                    "disconnect" -> {
                        closeSocket()
                        result.success(true)
                    }

                    "write" -> {
                        val data = call.argument<String>("data") ?: ""
                        handleWrite(data, result)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_BT_PERMS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermResult?.success(granted)
            pendingPermResult = null
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleGetPairedDevices(result: MethodChannel.Result) {
        if (!hasBluetoothPermissions()) {
            result.error("NO_PERMISSION", "Izin Bluetooth belum diberikan", null)
            return
        }
        val adapter = getBluetoothAdapter()
        if (adapter == null) {
            result.error("NO_BT", "Perangkat tidak memiliki Bluetooth", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth belum aktif. Nyalakan Bluetooth di HP Anda.", null)
            return
        }

        val devices = adapter.bondedDevices
            .map { dev ->
                mapOf(
                    "name" to (dev.name ?: "Unknown"),
                    "address" to dev.address
                )
            }
            .sortedWith(compareByDescending<Map<String, String>> {
                (it["name"] ?: "").contains("RTM", ignoreCase = true)
            }.thenBy { it["name"] ?: "" })

        result.success(devices)
    }

    @SuppressLint("MissingPermission")
    private fun handleConnect(address: String, result: MethodChannel.Result) {
        if (!hasBluetoothPermissions()) {
            result.error("NO_PERMISSION", "Izin Bluetooth belum diberikan", null)
            return
        }
        val adapter = getBluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth belum aktif", null)
            return
        }

        ioExecutor.execute {
            closeSocket()
            try {
                if (adapter.isDiscovering) {
                    adapter.cancelDiscovery()
                }
                val device = adapter.getRemoteDevice(address)
                var socket: BluetoothSocket? = null
                try {
                    socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                    socket.connect()
                } catch (e: IOException) {
                    try {
                        socket?.close()
                    } catch (_: IOException) {}
                    // Fallback to insecure RFCOMM socket for wider Android compatibility
                    socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                    socket.connect()
                }

                btSocket = socket
                btInput = socket.inputStream
                btOutput = socket.outputStream
                isReading = true

                startReaderThread()

                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                closeSocket()
                mainHandler.post {
                    result.error("CONNECT_FAILED", e.message ?: "Gagal menghubungkan ke perangkat", null)
                }
            }
        }
    }

    private fun startReaderThread() {
        ioExecutor.execute {
            val buffer = ByteArray(1024)
            try {
                while (isReading) {
                    val input = btInput ?: break
                    val bytesRead = input.read(buffer)
                    if (bytesRead == -1) break
                    if (bytesRead > 0) {
                        val chunk = String(buffer, 0, bytesRead, Charsets.UTF_8)
                        mainHandler.post {
                            eventSink?.success(mapOf("type" to "data", "payload" to chunk))
                        }
                    }
                }
            } catch (_: IOException) {
                // Socket closed or disconnected
            } finally {
                val wasReading = isReading
                closeSocket()
                if (wasReading) {
                    mainHandler.post {
                        eventSink?.success(mapOf("type" to "disconnected", "payload" to ""))
                    }
                }
            }
        }
    }

    private fun handleWrite(data: String, result: MethodChannel.Result) {
        val output = btOutput
        if (output == null || btSocket?.isConnected != true) {
            result.error("NOT_CONNECTED", "Belum terhubung ke perangkat Bluetooth", null)
            return
        }
        ioExecutor.execute {
            try {
                output.write(data.toByteArray(Charsets.UTF_8))
                output.flush()
                mainHandler.post { result.success(true) }
            } catch (e: IOException) {
                closeSocket()
                mainHandler.post {
                    eventSink?.success(mapOf("type" to "disconnected", "payload" to ""))
                    result.error("WRITE_FAILED", e.message ?: "Gagal mengirim data", null)
                }
            }
        }
    }

    private fun closeSocket() {
        isReading = false
        try { btInput?.close() } catch (_: IOException) {}
        try { btOutput?.close() } catch (_: IOException) {}
        try { btSocket?.close() } catch (_: IOException) {}
        btInput = null
        btOutput = null
        btSocket = null
    }

    override fun onDestroy() {
        closeSocket()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
