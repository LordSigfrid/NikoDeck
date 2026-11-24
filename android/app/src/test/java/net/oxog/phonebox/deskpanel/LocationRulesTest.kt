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
        assertEquals(setOf("lat", "lon", "city", "accuracyM"), j.keySet())
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
}
