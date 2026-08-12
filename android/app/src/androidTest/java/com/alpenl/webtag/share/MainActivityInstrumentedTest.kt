package com.alpenl.webtag.share

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test

class MainActivityInstrumentedTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun companionShellStartsOnTodayAndOpensAccessibleSettings() {
        composeRule.onAllNodesWithText("今日")[0].assertIsDisplayed()
        composeRule.onNodeWithText("待办").assertIsDisplayed()
        composeRule.onNodeWithText("传输").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("设置").performClick()
        composeRule.onNodeWithText("设置").assertIsDisplayed()
        composeRule.onNodeWithText("服务器地址").assertIsDisplayed()
    }
}
