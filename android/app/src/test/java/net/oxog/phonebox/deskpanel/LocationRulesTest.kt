package net.oxog.phonebox.deskpanel

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationRulesTest {
    @Test
    fun coordinatesAreRoundedToTwoDecimals() {
        assertEquals(-23.55, LocationRules.round2(-23.550520), 0.0)
        assertEquals(-46.63, LocationRules.round2(-46.633309), 0.0)
        assertEquals(59.44, LocationRules.round2(59.4449), 0.0)
        assertEquals(180.0, LocationRules.round2(179.999), 0.0)
    }

    @Test
    fun aFixYoungerThanHalfAnHourIsUsedAsItIs() {
        assertTrue(LocationRules.fresh(0))
        assertTrue(LocationRules.fresh(LocationRules.INTERVAL_MS - 1))
        assertFalse(LocationRules.fresh(LocationRules.INTERVAL_MS))
        assertFalse(LocationRules.fresh(-1)) // a clock that went backwards is not trusted
    }

    @Test
    fun theTownIsTheFirstNameTheGeocoderHas() {
        assertEquals("Campinas", LocationRules.townName(null, " Campinas ", "São Paulo"))
        assertEquals("São Paulo", LocationRules.townName("", "  ", "São Paulo"))
        assertEquals("ab", LocationRules.townName("a\nb"))
        assertNull(LocationRules.townName(null, null, null))
        assertEquals(LocationRules.MAX_CITY, LocationRules.townName("x".repeat(200))!!.length)
    }

    @Test
    fun theBodyCarriesOnlyTheRoundedPlaceTheTownAndTheAccuracy() {
        val j = JSONObject(LocationRules.body(-23.550520, -46.633309, "São Paulo", 1234.2))
        // keys(), not keySet(): android.jar hides keySet, and it is on the unit tests' compile classpath too
        assertEquals(setOf("lat", "lon", "city", "accuracyM"), j.keys().asSequence().toSet())
        assertEquals(-23.55, j.getDouble("lat"), 0.0)
        assertEquals(-46.63, j.getDouble("lon"), 0.0)
        assertEquals("São Paulo", j.getString("city"))
        assertEquals(1235.0, j.getDouble("accuracyM"), 0.0)
        // a precise fix still says "about a kilometre": the rounding is what the agent gets
        assertEquals(1000.0, JSONObject(LocationRules.body(1.0, 2.0, null, 5.0)).getDouble("accuracyM"), 0.0)
        val none = JSONObject(LocationRules.body(1.0, 2.0, null, Double.NaN))
        assertTrue(none.isNull("city"))
        assertTrue(none.isNull("accuracyM"))
    }

    private val day = 24 * 60 * 60_000L
    private val now = 100 * day

    @Test
    fun theFirstStartExplainsAndAsks() {
        // before any prompt Android's rationale is false; that is not a refusal
        assertTrue(LocationRules.shouldExplain(notNowAt = 0, now = now, requested = false, lastGranted = false, rationale = false))
    }

    @Test
    fun notNowPausesTheExplanationForAWeek() {
        assertFalse(LocationRules.shouldExplain(now - 1, now, requested = false, lastGranted = false, rationale = false))
        assertFalse(LocationRules.shouldExplain(now - 7 * day + 1, now, requested = true, lastGranted = false, rationale = true))
        assertTrue(LocationRules.shouldExplain(now - 7 * day, now, requested = false, lastGranted = false, rationale = false))
        assertTrue(LocationRules.shouldExplain(now - 7 * day, now, requested = true, lastGranted = false, rationale = true))
        // a clock set back does not stretch the pause
        assertTrue(LocationRules.shouldExplain(now + day, now, requested = false, lastGranted = false, rationale = false))
    }

    @Test
    fun aDenialIsAskedAgainOnlyWhileAndroidAllowsIt() {
        // one "Deny": Android still offers the prompt
        assertTrue(LocationRules.shouldExplain(0, now, requested = true, lastGranted = false, rationale = true))
        // denied and no rationale after a prompt: permanent, never asked again
        assertFalse(LocationRules.shouldExplain(0, now, requested = true, lastGranted = false, rationale = false))
    }

    @Test
    fun aWithdrawnGrantIsAskedAgain() {
        // "Only this time" that lapsed, or taken back in settings: Android's rationale may be false, still not a refusal
        assertTrue(LocationRules.shouldExplain(0, now, requested = true, lastGranted = true, rationale = false))
        // granted in Android's settings without the app's prompt, then taken back
        assertTrue(LocationRules.shouldExplain(0, now, requested = false, lastGranted = true, rationale = false))
    }
}
