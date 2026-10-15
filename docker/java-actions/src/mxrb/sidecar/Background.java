package mxrb.sidecar;

import java.io.IOException;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import com.mendix.core.CoreRuntimeException;

/**
 * Work a Java action leaves running after it returns, such as a listener of
 * MQTT messages that calls a microflow. The Ruby application keeps a listen
 * connection open; for each callback of such work the sidecar asks it, on that
 * connection, to attach a new connection, on which the callback runs in a
 * transaction of its own with a system context.
 */
public final class Background {
	private static final long WAIT_SECONDS = Long
			.parseLong(System.getenv().getOrDefault("MXRB_JAVA_ACTIONS_TIMEOUT", "300"));
	private static final Map<String, CompletableFuture<Attached>> WAITING = new ConcurrentHashMap<>();
	private static volatile Bridge listener;

	private Background() {
	}

	/** Keeps a listen connection until the Ruby application closes it. */
	static void listen(Bridge bridge) throws IOException {
		listener = bridge;
		try {
			bridge.awaitClose();
		} finally {
			if (listener == bridge) {
				listener = null;
			}
		}
	}

	/** Hands an attach connection to the work that asked for it, until that work is done with it. */
	static void attach(Bridge bridge, String ticket) throws InterruptedException {
		CompletableFuture<Attached> waiting = WAITING.remove(ticket);
		if (waiting == null) {
			throw new IllegalStateException("no background work waits for " + ticket);
		}
		Attached attached = new Attached(bridge);
		waiting.complete(attached);
		attached.done.await();
	}

	/** One callback of work outside an invocation, on a connection of its own. */
	static Object call(String method, Object... parameters) {
		Bridge channel = listener;
		if (channel == null) {
			throw new CoreRuntimeException("no Ruby application listens for the sidecar's background work");
		}
		String ticket = UUID.randomUUID().toString();
		CompletableFuture<Attached> waiting = new CompletableFuture<>();
		WAITING.put(ticket, waiting);
		Attached attached;
		try {
			channel.notify("attach", "ticket", ticket);
			attached = waiting.get(WAIT_SECONDS, TimeUnit.SECONDS);
		} catch (Exception e) {
			WAITING.remove(ticket);
			throw new CoreRuntimeException("the Ruby application did not attach background work", e);
		}
		try {
			return attached.bridge.call(method, parameters);
		} finally {
			attached.done.countDown();
		}
	}

	private static final class Attached {
		private final Bridge bridge;
		private final CountDownLatch done = new CountDownLatch(1);

		Attached(Bridge bridge) {
			this.bridge = bridge;
		}
	}
}
