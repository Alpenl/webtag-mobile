package com.alpenl.webtag.share.contract

import java.net.URI
import java.util.Locale

object OriginNormalizer {
    fun normalize(raw: String): String {
        val value = raw.trim()
        require(value.isNotEmpty()) { "origin is empty" }
        val uri = URI(value)
        require(uri.scheme.equals("https", ignoreCase = true)) { "origin must use HTTPS" }
        require(uri.host != null) { "origin host is missing" }
        require(uri.userInfo == null) { "origin userinfo is not allowed" }
        require(uri.query == null && uri.fragment == null) { "origin query and fragment are not allowed" }
        require(uri.path.isNullOrEmpty() || uri.path == "/") { "origin path must be root" }
        val host = uri.host.lowercase(Locale.ROOT)
        val port = uri.port.takeUnless { it == -1 || it == 443 }
        return buildString {
            append("https://")
            if (host.contains(':')) append('[').append(host).append(']') else append(host)
            port?.let { append(':').append(it) }
        }
    }
}
