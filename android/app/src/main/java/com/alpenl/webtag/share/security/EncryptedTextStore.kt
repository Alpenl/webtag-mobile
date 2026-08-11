package com.alpenl.webtag.share.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.alpenl.webtag.share.contract.CredentialConfig
import com.alpenl.webtag.share.contract.ActiveSessionSnapshot
import com.alpenl.webtag.share.contract.LEGACY_ACTIVATION_REVISION
import com.alpenl.webtag.share.contract.OriginNormalizer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class EncryptedValue(
    val ciphertext: ByteArray,
    val nonce: ByteArray,
    val version: Int = 1,
)

class AndroidKeystoreCipher(
    private val alias: String,
) {
    fun encrypt(value: String, aad: String): EncryptedValue {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // Android Keystore requires its randomized IV when randomized encryption is enabled.
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val nonce = cipher.iv ?: error("Keystore did not return a GCM nonce")
        return EncryptedValue(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), nonce)
    }

    fun decrypt(value: EncryptedValue, aad: String): String {
        require(value.version == 1) { "unsupported crypto version" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, value.nonce))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(value.ciphertext).toString(Charsets.UTF_8)
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}

class EncryptedCredentialStore(
    context: Context,
    private val cipher: AndroidKeystoreCipher = AndroidKeystoreCipher("webtag-share-credentials-v1"),
) {
    private val directory = context.filesDir
    private val file = File(directory, "credential.v1")
    private val pendingPrefix = "credential.pending."

    @Synchronized
    fun save(config: CredentialConfig) {
        write(file, config)
    }

    @Synchronized
    fun stage(config: CredentialConfig) {
        write(pendingFile(config.activationRevision), config)
    }

    @Synchronized
    fun promoteStaged(revision: Long): CredentialConfig {
        val pending = pendingFile(revision)
        val config = read(pending) ?: error("staged credential is missing")
        require(config.activationRevision == revision) { "staged credential revision mismatch" }
        moveAtomically(pending, file)
        return config
    }

    @Synchronized
    fun discardStaged(revision: Long) {
        pendingFile(revision).delete()
    }

    @Synchronized
    fun recover(snapshot: ActiveSessionSnapshot): CredentialConfig? {
        val active = read(file)
        if (active.matches(snapshot)) {
            discardPendingThrough(snapshot.activationRevision)
            return active
        }
        val staged = read(pendingFile(snapshot.activationRevision))
        if (staged.matches(snapshot)) {
            return promoteStaged(snapshot.activationRevision)
        }
        return null
    }

    @Synchronized
    fun load(): CredentialConfig? = read(file)

    @Synchronized
    fun clear() {
        file.delete()
        directory.listFiles { candidate -> candidate.name.startsWith(pendingPrefix) }
            .orEmpty()
            .forEach(File::delete)
    }

    private fun write(target: File, config: CredentialConfig) {
        val normalizedOrigin = OriginNormalizer.normalize(config.origin)
        require(normalizedOrigin == config.origin) { "credential origin is not canonical" }
        require(config.apiKey.isNotBlank()) { "credential API key is empty" }
        require(isNamespace(config.namespace)) { "credential namespace is invalid" }
        require(config.scopes.all(String::isNotBlank)) { "credential scope is empty" }
        require(config.activationRevision > 0) { "credential activation revision is invalid" }
        val payload = JSONObject()
            .put("origin", config.origin)
            .put("api_key", config.apiKey)
            .put("namespace", config.namespace)
            .put("representation_contract", "v2")
            .put("activation_revision", config.activationRevision)
            .put(
                "scopes",
                JSONArray().apply { config.scopes.toList().sorted().forEach(::put) },
            )
            .toString()
        val encrypted = cipher.encrypt(payload, aad(config.activationRevision))
        val json = JSONObject()
            .put("version", encrypted.version)
            .put("activation_revision", config.activationRevision)
            .put("nonce", android.util.Base64.encodeToString(encrypted.nonce, android.util.Base64.NO_WRAP))
            .put("ciphertext", android.util.Base64.encodeToString(encrypted.ciphertext, android.util.Base64.NO_WRAP))
        val temporary = File(target.parentFile, "${target.name}.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(json.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        try {
            moveAtomically(temporary, target)
        } finally {
            temporary.delete()
        }
    }

    private fun read(source: File): CredentialConfig? {
        if (!source.isFile) return null
        val json = JSONObject(source.readText(Charsets.UTF_8))
        val hasRevision = json.has("activation_revision")
        val wrapperRevision = if (hasRevision) json.getLong("activation_revision") else LEGACY_ACTIVATION_REVISION
        require(wrapperRevision > 0) { "credential activation revision is invalid" }
        val encrypted = EncryptedValue(
            ciphertext = android.util.Base64.decode(json.getString("ciphertext"), android.util.Base64.DEFAULT),
            nonce = android.util.Base64.decode(json.getString("nonce"), android.util.Base64.DEFAULT),
            version = json.getInt("version"),
        )
        val payload = JSONObject(
            cipher.decrypt(
                encrypted,
                if (hasRevision) aad(wrapperRevision) else LEGACY_AAD,
            ),
        )
        val scopes = buildSet {
            val values = payload.getJSONArray("scopes")
            for (index in 0 until values.length()) add(values.getString(index))
        }
        val origin = payload.getString("origin")
        require(OriginNormalizer.normalize(origin) == origin) { "credential origin is not canonical" }
        val apiKey = payload.getString("api_key")
        val namespace = payload.getString("namespace")
        require(apiKey.isNotBlank()) { "credential API key is empty" }
        require(isNamespace(namespace)) { "credential namespace is invalid" }
        // v1 encrypted files predate the explicit contract field but were only
        // written after the v2 session response had been validated.
        require(payload.optString("representation_contract", "v2") == "v2") {
            "unsupported credential contract"
        }
        val activationRevision = payload.optLong("activation_revision", wrapperRevision)
        require(activationRevision == wrapperRevision && activationRevision > 0) {
            "credential activation revision mismatch"
        }
        require(scopes.all(String::isNotBlank)) { "credential scope is empty" }
        return CredentialConfig(
            origin = origin,
            apiKey = apiKey,
            namespace = namespace,
            scopes = scopes,
            activationRevision = activationRevision,
        )
    }

    private fun CredentialConfig?.matches(snapshot: ActiveSessionSnapshot): Boolean =
        this != null && activationRevision == snapshot.activationRevision && sessionIdentity() == snapshot.identity

    private fun discardPendingThrough(revision: Long) {
        directory.listFiles { candidate -> candidate.name.startsWith(pendingPrefix) }
            .orEmpty()
            .filter { candidate -> candidate.name.removePrefix(pendingPrefix).toLongOrNull()?.let { it <= revision } == true }
            .forEach(File::delete)
    }

    private fun pendingFile(revision: Long): File {
        require(revision > 0) { "credential activation revision is invalid" }
        return File(directory, "$pendingPrefix$revision")
    }

    private fun aad(revision: Long): String = "credential-v2|$revision"

    private fun moveAtomically(source: File, target: File) {
        try {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: IOException) {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } catch (_: UnsupportedOperationException) {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun isNamespace(value: String): Boolean =
        value.length == 43 && value.all {
            it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
        }

    private companion object {
        const val LEGACY_AAD = "credential-v1"
    }
}
