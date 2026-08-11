package com.alpenl.webtag.share

import android.content.ClipData
import android.content.Intent
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.rules.ActivityScenarioRule
import org.junit.Rule
import org.junit.Test

class ShareActivityInstrumentedTest {
    private val launchIntent = Intent(Intent.ACTION_SEND)
        .setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, "标题 https://one.example/article?utm=abc#top")
        .apply {
            // A second, unrelated link that only exists in ClipData: EXTRA_TEXT must not hide it.
            clipData = ClipData.newPlainText("shared", "另一篇 https://two.example/story?ref=xyz")
        }
        .setClassName("com.alpenl.webtag.share", ShareActivity::class.java.name)

    @get:Rule
    val composeRule: AndroidComposeTestRule<
        ActivityScenarioRule<ShareActivity>,
        ShareActivity,
    > = AndroidComposeTestRule(ActivityScenarioRule(launchIntent)) { rule ->
        var activity: ShareActivity? = null
        rule.scenario.onActivity { activity = it }
        checkNotNull(activity)
    }

    @Test
    fun everyCandidateIsOfferedAsAButtonLabelledWithHostAndPathOnly() {
        composeRule.waitForIdle()

        composeRule.onNodeWithText("one.example/article")
            .assertIsDisplayed()
            .assertHasClickAction()
        composeRule.onNodeWithText("two.example/story")
            .assertIsDisplayed()
            .assertHasClickAction()
    }

    @Test
    fun theRawUrlWithItsQueryAndFragmentNeverReachesTheScreen() {
        composeRule.waitForIdle()

        composeRule.onNodeWithText("https://one.example/article?utm=abc#top").assertDoesNotExist()
        composeRule.onNodeWithText("https://two.example/story?ref=xyz").assertDoesNotExist()
        composeRule.onNodeWithText("utm=abc", substring = true).assertDoesNotExist()
        composeRule.onNodeWithText("ref=xyz", substring = true).assertDoesNotExist()
    }
}
