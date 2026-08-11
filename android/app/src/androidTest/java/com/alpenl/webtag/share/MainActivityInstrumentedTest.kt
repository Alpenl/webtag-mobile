package com.alpenl.webtag.share

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test

class MainActivityInstrumentedTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun settingsSurfaceExposesAccessibleConfigurationHeading() {
        composeRule.onNodeWithText("WebTag Share").assertIsDisplayed()
        composeRule.onNodeWithText("服务器地址").assertIsDisplayed()
    }
}
