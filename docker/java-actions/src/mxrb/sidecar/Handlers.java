package mxrb.sidecar;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import com.mendix.externalinterface.connector.RequestHandler;

/** The request handlers Core.addRequestHandler registered, by path. */
public final class Handlers {
	private static final Map<String, RequestHandler> HANDLERS = new ConcurrentHashMap<>();

	private Handlers() {
	}

	/** A handler's path without slashes around it, such as "link". */
	public static String key(String path) {
		return path.replaceAll("^/+|/+$", "");
	}

	public static void register(String path, RequestHandler handler) {
		HANDLERS.put(key(path), handler);
	}

	static RequestHandler find(String path) {
		return HANDLERS.get(key(path));
	}
}
