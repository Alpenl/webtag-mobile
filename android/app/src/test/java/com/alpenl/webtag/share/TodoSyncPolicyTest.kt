package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.data.TodoOutboxState
import com.alpenl.webtag.share.todo.TodoSyncCoordinator
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test

class TodoSyncPolicyTest {
    @Test
    fun transientTransportAndServerFailuresWaitForRetry() {
        listOf(
            ErrorKind.NO_NETWORK,
            ErrorKind.DNS_TIMEOUT,
            ErrorKind.CONNECTION_RESET,
            ErrorKind.CLIENT_DEADLINE,
            ErrorKind.HTTP_408,
            ErrorKind.HTTP_425,
            ErrorKind.HTTP_429_RATE_LIMIT,
            ErrorKind.HTTP_5XX,
        ).forEach { kind ->
            assertEquals(kind.name, TodoOutboxState.RETRY_WAIT, TodoSyncCoordinator.stateFor(kind))
        }
    }

    @Test
    fun identityCredentialConflictAndPermanentFailuresRemainDistinct() {
        assertEquals(TodoOutboxState.BLOCKED_AUTH, TodoSyncCoordinator.stateFor(ErrorKind.HTTP_401))
        assertEquals(TodoOutboxState.BLOCKED_SCOPE, TodoSyncCoordinator.stateFor(ErrorKind.HTTP_403_SCOPE))
        assertEquals(TodoOutboxState.BLOCKED_IDENTITY, TodoSyncCoordinator.stateFor(ErrorKind.IDENTITY_MISMATCH))
        assertEquals(TodoOutboxState.CONFLICT, TodoSyncCoordinator.stateFor(ErrorKind.HTTP_409))
        assertEquals(TodoOutboxState.FAILED_PERMANENT, TodoSyncCoordinator.stateFor(ErrorKind.TLS_TRUST_FAILURE))
    }

    @Test
    fun retryBackoffStartsAtThirtySecondsAndCapsAtSixHours() {
        val now = 10_000L
        assertEquals(now + 30_000, TodoSyncCoordinator.retryAt(1, now))
        assertEquals(now + 60_000, TodoSyncCoordinator.retryAt(2, now))
        assertEquals(now + TimeUnit.HOURS.toMillis(6), TodoSyncCoordinator.retryAt(99, now))
    }
}
