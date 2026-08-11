package com.alpenl.webtag.share.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF006C4C),
    onPrimary = Color.White,
    secondary = Color(0xFF4F6357),
    tertiary = Color(0xFF3F6374),
    background = Color(0xFFF9FAF7),
    surface = Color(0xFFFFFFFF),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF5CDBA8),
    onPrimary = Color(0xFF003826),
    secondary = Color(0xFFB6CCBE),
    tertiary = Color(0xFFA7CDDF),
    background = Color(0xFF111411),
    surface = Color(0xFF191C19),
)

@Composable
fun WebTagShareTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        content = content,
    )
}
