package net.oxog.phonebox.deskpanel

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * The rules of [PhoneLocation] that need no Android: rounding, how often, what is sent. Plain Kotlin so the JVM unit
 * tests can check them.
 */
object LocationRules {
    /** At most one location every 30 minutes; a fix younger than that is used as it is, without asking for a new one. */
    const val INTERVAL_MS = 30 * 60_000L
    /** After the agent could not be reached (no cable, no Wi-Fi), try again sooner. */
    const val RETRY_MS = 5 * 60_000L
    const val MAX_CITY = 80

    /** Two decimals, about 1 km: enough for the weather, not a street address. Applied before anything leaves the phone. */
    fun round2(v: Double): Double = BigDecimal.valueOf(v).setScale(2, RoundingMode.HALF_UP).toDouble()

    fun fresh(ageMs: Long): Boolean = ageMs in 0 until INTERVAL_MS

    /** After "Not now" in the app's explanation, it is not shown again for a week. */
    const val NOT_NOW_COOLDOWN_MS = 7 * 24 * 60 * 60_000L

    /**
     * Whether to show the explanation (and then Android's prompt) while the permission is missing, on Android 6+.
     * [notNowAt]: wall-clock time of the last "Not now" in the explanation, 0 for none. [requested]: Android's prompt
     * was answered at least once. [lastGranted]: the permission was granted the last time the app saw it (a one-time
     * "Only this time" that lapsed, or one taken back in Android's settings). [rationale]: Android's
     * shouldShowRequestPermissionRationale, true while Android still allows another prompt after a denial.
     */
    fun shouldExplain(notNowAt: Long, now: Long, requested: Boolean, lastGranted: Boolean, rationale: Boolean): Boolean {
        // a clock set back (negative age) ends the pause rather than stretching it
        if (notNowAt > 0 && now - notNowAt in 0 until NOT_NOW_COOLDOWN_MS) return false
        if (!requested) return true // never asked: Android's rationale is false here, but that is not a refusal
        // denied and Android no longer offers the prompt: a permanent refusal, never asked again (settings still work)
        return lastGranted || rationale
    }

    /** The town for the weather line: the locality, else the district or the region; null when the Geocoder had none. */
    fun townName(vararg names: String?): String? =
        names.firstNotNullOfOrNull { n -> n?.filterNot { it.isISOControl() }?.trim()?.takeIf { it.isNotEmpty() } }?.take(MAX_CITY)

    /** The POST /api/phone/location body. [accuracyM] is rounded up to whole metres and never below the ~1 km rounding. */
    fun body(lat: Double, lon: Double, city: String?, accuracyM: Double?): String = JSONObject()
        .put("lat", round2(lat))
        .put("lon", round2(lon))
        .put("city", city ?: JSONObject.NULL)
        .put("accuracyM", if (accuracyM == null || !accuracyM.isFinite() || accuracyM < 0) JSONObject.NULL else maxOf(1000.0, kotlin.math.ceil(accuracyM)))
        .toString()
}

/**
 * Settings › General › Weather › "Use the phone's location": the phone's approximate location becomes the weather
 * location. Only coarse location is used (ACCESS_COARSE_LOCATION, never fine or background), from Android's own
 * LocationManager, so no Google Play services are needed; the town name comes from Android's on-device Geocoder when
 * the phone has one. The coordinates are rounded to about 1 km before they are geocoded or sent, and go only to the
 * NikoDeck agent, over the same USB / paired Wi-Fi link as everything else (AgentLink).
 *
 * The permission is asked after a short explanation ([ask]), at most once per app start: "Not now" there pauses it for a
 * week; after Android's "Deny" it is asked again on a later start only while Android still allows it
 * ([LocationRules.shouldExplain]), and never after a permanent refusal (the computer's settings page says how to allow
 * it in Android's app settings, which works at once). Without the permission or a location, nothing is sent and the
 * agent keeps the location it has. Runs only while the panel is in front; pausing cancels a fix in progress.
 */
class PhoneLocation(
    private val activity: Activity,
    private val link: AgentLink,
    private val prefs: SharedPreferences,
    /** Shows the explanation and calls back with true when the user wants to continue to Android's prompt. */
    private val ask: (answer: (Boolean) -> Unit) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    // main thread only
    private var auto = false
    private var resumed = false
    private var asking = false
    private var askedThisStart = false // the explanation is shown at most once per app start
    private var busy = false
    private var nextAt = 0L // SystemClock.elapsedRealtime(); 0 = as soon as possible (the first run after the app starts)
    private val tick = Runnable { run() }
    /** Stops the fix in progress on the worker (any thread; set and cleared by [current]). */
    private val stopFix = AtomicReference<(() -> Unit)?>()
    /** Bumped by [cancelFix]: a run started under an older value sends nothing. */
    @Volatile private var generation = 0

    /** From the panel (any thread): whether the agent's settings have the automatic location on. */
    fun setAuto(on: Boolean) = main.post {
        if (on == auto) return@post
        auto = on
        if (on) start() else { main.removeCallbacks(tick); cancelFix() }
    }

    fun resume() = main.post { resumed = true; start() }

    fun pause() = main.post { resumed = false; main.removeCallbacks(tick); cancelFix() }

    fun close() {
        main.removeCallbacks(tick)
        cancelFix()
        worker.shutdownNow()
    }

    /** Ends a fix in progress at once: the worker then sends nothing and the next resume tries again. */
    private fun cancelFix() {
        generation++ // written on the main thread only (close() from onDestroy too)
        stopFix.getAndSet(null)?.invoke()
    }

    /** From MainActivity.onRequestPermissionsResult; null when the prompt was interrupted without an answer. */
    fun onPermission(granted: Boolean?) = main.post {
        asking = false
        if (granted == null) return@post
        prefs.edit().putBoolean(REQUESTED, true).putBoolean(GRANTED, granted).apply()
        if (granted) start()
    }

    private fun granted() = Build.VERSION.SDK_INT < 23 ||
        activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun start() {
        if (!auto || !resumed || activity.isFinishing) return
        if (granted()) {
            // allowed here or in Android's settings: remembered, so a later withdrawal ("Only this time") asks again
            if (!prefs.getBoolean(GRANTED, false)) prefs.edit().putBoolean(GRANTED, true).apply()
            main.removeCallbacks(tick); main.post(tick); return
        }
        if (asking || askedThisStart || Build.VERSION.SDK_INT < 23) return
        val explain = LocationRules.shouldExplain(
            notNowAt = prefs.getLong(NOT_NOW_AT, 0L),
            now = System.currentTimeMillis(),
            requested = prefs.getBoolean(REQUESTED, false),
            lastGranted = prefs.getBoolean(GRANTED, false),
            rationale = Build.VERSION.SDK_INT >= 23 &&
                activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION),
        )
        if (!explain) return
        asking = true
        askedThisStart = true
        ask { go ->
            asking = false
            if (!go) {
                // only this explicit "Not now" is remembered; Android's own answer comes back in onPermission
                prefs.edit().putLong(NOT_NOW_AT, System.currentTimeMillis()).apply()
            } else {
                prefs.edit().remove(NOT_NOW_AT).apply()
                if (Build.VERSION.SDK_INT >= 23 && !activity.isFinishing) {
                    asking = true // until onPermission
                    activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), PERMISSION_REQUEST)
                }
            }
        }
    }

    private fun run() {
        main.removeCallbacks(tick)
        if (!auto || !resumed || !granted()) return
        val now = SystemClock.elapsedRealtime()
        if (busy || now < nextAt) { main.postDelayed(tick, maxOf(60_000L, nextAt - now)); return }
        busy = true
        nextAt = now + LocationRules.INTERVAL_MS
        val gen = generation
        try {
            worker.execute {
                val reached = try { report(gen) } catch (e: Exception) { Log.w("NikoDeck", "location: ${e.javaClass.simpleName}"); true }
                main.post {
                    busy = false
                    if (gen != generation) nextAt = 0L // cut short by a pause: the next resume tries again at once
                    else if (!reached) nextAt = SystemClock.elapsedRealtime() + LocationRules.RETRY_MS
                    if (auto && resumed) main.postDelayed(tick, maxOf(60_000L, nextAt - SystemClock.elapsedRealtime()))
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) { busy = false } // closed
    }

    /** Finds the location and sends it. False only when the agent could not be reached, so the next try comes sooner. */
    private fun report(gen: Int): Boolean {
        val loc = locate(gen) ?: return true // no location: nothing is sent, the agent keeps the one it has
        if (gen != generation) return true // paused meanwhile: nothing is sent
        val lat = LocationRules.round2(loc.latitude)
        val lon = LocationRules.round2(loc.longitude)
        val body = LocationRules.body(lat, lon, townName(lat, lon), if (loc.hasAccuracy()) loc.accuracy.toDouble() else null)
        val r = link.request("POST", "/api/phone/location", body.toByteArray(Charsets.UTF_8), "application/json")
        try { r.body.close() } catch (_: Exception) {}
        return r.code != 503 && r.code != 504
    }

    @SuppressLint("MissingPermission") // granted() is checked before every run
    private fun locate(gen: Int): Location? {
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        val known = PROVIDERS.mapNotNull { p ->
            // with coarse location only, Android before 12 refuses the GPS provider: a SecurityException, skipped
            try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } catch (_: IllegalArgumentException) { null }
        }
        val newest = known.maxByOrNull { it.elapsedRealtimeNanos }
        if (newest != null && LocationRules.fresh(age(newest))) return newest
        return current(lm, gen) ?: newest
    }

    private fun age(l: Location) = (SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 1_000_000

    /**
     * One new fix, waiting at most [FIX_TIMEOUT_MS]; on the worker thread. The request is always withdrawn on the way
     * out (a fix, the timeout, a pause through [stopFix], or close() interrupting the wait).
     */
    @SuppressLint("MissingPermission")
    private fun current(lm: LocationManager, gen: Int): Location? {
        val provider = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
            .firstOrNull { p -> try { lm.isProviderEnabled(p) } catch (_: Exception) { false } } ?: return null
        val got = AtomicReference<Location?>()
        val done = CountDownLatch(1)
        val cancel = CancellationSignal() // used from Android 11, where getCurrentLocation exists
        val listener = SingleFix { l -> got.set(l); done.countDown() } // used before Android 11
        val stop = { if (Build.VERSION.SDK_INT >= 30) cancel.cancel() else lm.removeUpdates(listener) }
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                lm.getCurrentLocation(provider, cancel, java.util.concurrent.Executor { it.run() }) { l: Location? -> got.set(l); done.countDown() }
            } else {
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        } catch (_: SecurityException) { return null } catch (_: IllegalArgumentException) { return null }
        val stopNow: () -> Unit = { try { stop() } catch (_: Exception) {}; done.countDown() }
        stopFix.set(stopNow)
        try {
            if (gen == generation) done.await(FIX_TIMEOUT_MS, TimeUnit.MILLISECONDS) // else paused before it was set
        } finally {
            stopFix.compareAndSet(stopNow, null)
            try { stop() } catch (_: Exception) {} // cancelling a finished request does nothing
        }
        return if (gen == generation) got.get() else null
    }

    /** Every method spelled out: Android before 11 has no default methods on LocationListener to fall back on. */
    private class SingleFix(private val fix: (Location) -> Unit) : LocationListener {
        override fun onLocationChanged(location: Location) = fix(location)
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    /** The town at the rounded point, from Android's Geocoder (it may ask the phone's location services provider). */
    private fun townName(lat: Double, lon: Double): String? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(activity, Locale.getDefault())
        val address: Address? = try {
            if (Build.VERSION.SDK_INT >= 33) {
                val got = AtomicReference<Address?>()
                val done = CountDownLatch(1)
                geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) { got.set(addresses.firstOrNull()); done.countDown() }
                    override fun onError(errorMessage: String?) { done.countDown() }
                })
                done.await(GEOCODE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                got.get()
            } else {
                @Suppress("DEPRECATION")
                geocoder.getFromLocation(lat, lon, 1)?.firstOrNull()
            }
        } catch (_: Exception) { null } // no network for the geocoder, or none installed: the agent shows the coordinates
        return LocationRules.townName(address?.locality, address?.subAdminArea, address?.adminArea)
    }

    companion object {
        const val PERMISSION_REQUEST = 42
        /** Wall-clock time of the last "Not now" in the explanation (absent: none). */
        private const val NOT_NOW_AT = "location-not-now-at"
        /** Android's prompt was answered at least once. */
        private const val REQUESTED = "location-requested"
        /** The permission was granted the last time the app saw it. */
        private const val GRANTED = "location-granted"
        private const val FIX_TIMEOUT_MS = 30_000L
        private const val GEOCODE_TIMEOUT_MS = 10_000L
        private val PROVIDERS = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER, LocationManager.GPS_PROVIDER)
    }
}
