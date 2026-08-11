package com.alpenl.webtag.share

import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectConfigurationTest {
    @Test
    fun applicationIdMatchesTheProjectContract() {
        assertEquals("com.alpenl.webtag.share", BuildConfig.APPLICATION_ID)
    }
}
