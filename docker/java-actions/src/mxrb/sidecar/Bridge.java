package mxrb.sidecar;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Writer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.core.CoreRuntimeException;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;

/**
 * One invocation from the Ruby application: the action to run and the
 * callbacks it makes, as JSON messages, one per line, on the same connection.
 */
public final class Bridge {
	private static final ThreadLocal<Bridge> CURRENT = new ThreadLocal<>();

	private final BufferedReader in;
	private final Writer out;
	private final Map<Long, MxObject> objects = new HashMap<>();
	private long next = 1;

	public Bridge(BufferedReader in, Writer out) {
		this.in = in;
		this.out = out;
	}

	/** The bridge of the invocation running on this thread. */
	public static Bridge current() {
		Bridge bridge = CURRENT.get();
		if (bridge == null) {
			throw new CoreRuntimeException("no action invocation is running on this thread");
		}
		return bridge;
	}

	static Bridge peek() {
		return CURRENT.get();
	}

	/** Serves the invocation the connection starts with. */
	@SuppressWarnings("unchecked")
	public void serve(Invoker invoker, String token) throws IOException {
		Map<String, Object> message = read();
		Map<String, Object> params = (Map<String, Object>) message.get("params");
		Object method = message.get("method");
		if (!("invoke".equals(method) || "request".equals(method)) || params == null) {
			throw new IOException("the connection must start with an invoke or a request message");
		}
		Map<String, Object> answer = new LinkedHashMap<>();
		answer.put("id", 0L);
		CURRENT.set(this);
		try {
			authorize(token, (String) params.get("token"));
			if ("request".equals(method)) {
				answer.put("result", encode(handle(params)));
			} else {
				List<Object[]> arguments = new ArrayList<>();
				for (Object pair : (List<Object>) params.get("arguments")) {
					List<Object> entry = (List<Object>) pair;
					arguments.add(new Object[] { entry.get(0), decode(entry.get(1)) });
				}
				Object result = invoker.invoke(new MxContext(this, false), (String) params.get("action"), arguments);
				answer.put("result", encode(result));
			}
		} catch (Throwable error) {
			Map<String, Object> details = new LinkedHashMap<>();
			details.put("type", error instanceof RubyException ruby ? ruby.type() : error.getClass().getName());
			details.put("message", error.getMessage() == null ? "" : error.getMessage());
			answer.put("error", details);
		} finally {
			CURRENT.remove();
		}
		send(answer);
	}

	/** A request the Ruby application's server forwards to the handler registered for its path. */
	@SuppressWarnings("unchecked")
	private Map<String, Object> handle(Map<String, Object> params) throws Exception {
		String path = (String) params.get("handler");
		com.mendix.externalinterface.connector.RequestHandler handler = Handlers.find(path);
		if (handler == null) {
			throw new IllegalStateException("no request handler for " + path);
		}
		Map<String, Object> session = (Map<String, Object>) decode(params.get("session"));
		MxRuntimeRequest request = new MxRuntimeRequest((Map<String, Object>) decode(params.get("request")), path,
				session == null ? null : new MxSession(this, session));
		MxRuntimeResponse response = new MxRuntimeResponse();
		handler.doProcessRequest(request, response, request.handlerPath());
		return response.result();
	}

	/** A callback to the Ruby application with its parameters as name, value pairs. */
	public synchronized Object call(String method, Object... parameters) {
		long id = next++;
		Map<String, Object> params = new LinkedHashMap<>();
		for (int i = 0; i < parameters.length; i += 2) {
			params.put((String) parameters[i], encode(parameters[i + 1]));
		}
		Map<String, Object> message = new LinkedHashMap<>();
		message.put("id", id);
		message.put("method", method);
		message.put("params", params);
		try {
			send(message);
			Map<String, Object> answer = read();
			if (!Long.valueOf(id).equals(answer.get("id"))) {
				throw new CoreRuntimeException("the Ruby application answered out of order");
			}
			if (answer.containsKey("error")) {
				@SuppressWarnings("unchecked")
				Map<String, Object> error = (Map<String, Object>) answer.get("error");
				throw new RubyException((String) error.get("type"), (String) error.get("message"));
			}
			return decode(answer.get("result"));
		} catch (IOException e) {
			throw new CoreRuntimeException("the Ruby application closed the connection", e);
		}
	}

	Object encode(Object value) {
		if (value == null || value instanceof String || value instanceof Boolean || value instanceof Long) {
			return value;
		}
		if (value instanceof Integer || value instanceof Short || value instanceof Byte) {
			return ((Number) value).longValue();
		}
		if (value instanceof BigDecimal decimal) {
			return Map.of("$decimal", decimal.toPlainString());
		}
		if (value instanceof Double || value instanceof Float) {
			return Map.of("$decimal", new BigDecimal(value.toString()).toPlainString());
		}
		if (value instanceof Date date) {
			return Map.of("$datetime", date.getTime());
		}
		if (value instanceof MxObject object) {
			return Map.of("$object", object.handle());
		}
		if (value instanceof IMendixIdentifier id) {
			return encode(id.getObject());
		}
		if (value instanceof byte[] bytes) {
			return Map.of("$binary", java.util.Base64.getEncoder().encodeToString(bytes));
		}
		if (value instanceof Enum<?> constant) {
			return constant.name();
		}
		if (value instanceof Collection<?> values) {
			List<Object> list = new ArrayList<>();
			for (Object item : values) {
				list.add(encode(item));
			}
			return list;
		}
		if (value instanceof Map<?, ?> map) {
			Map<String, Object> encoded = new LinkedHashMap<>();
			map.forEach((key, item) -> encoded.put(String.valueOf(key), encode(item)));
			return encoded;
		}
		throw new IllegalArgumentException("cannot pass " + value.getClass().getName() + " to the Ruby application");
	}

	@SuppressWarnings("unchecked")
	Object decode(Object value) {
		if (value instanceof List<?> list) {
			List<Object> decoded = new ArrayList<>();
			for (Object item : list) {
				decoded.add(decode(item));
			}
			return decoded;
		}
		if (!(value instanceof Map<?, ?>)) {
			return value;
		}
		Map<String, Object> tagged = (Map<String, Object>) value;
		if (tagged.isEmpty() || !tagged.keySet().iterator().next().startsWith("$")) {
			Map<String, Object> decoded = new LinkedHashMap<>();
			tagged.forEach((key, item) -> decoded.put(key, decode(item)));
			return decoded;
		}
		if (tagged.containsKey("$integer")) {
			return ((Long) tagged.get("$integer")).intValue();
		}
		if (tagged.containsKey("$decimal")) {
			return new BigDecimal((String) tagged.get("$decimal"));
		}
		if (tagged.containsKey("$datetime")) {
			return new Date((Long) tagged.get("$datetime"));
		}
		if (tagged.containsKey("$binary")) {
			return java.util.Base64.getDecoder().decode((String) tagged.get("$binary"));
		}
		if (tagged.containsKey("$object")) {
			long handle = (Long) tagged.get("$object");
			return objects.computeIfAbsent(handle,
					key -> new MxObject(this, key, (String) tagged.get("entity"), (String) tagged.get("id")));
		}
		throw new IllegalArgumentException("the Ruby application sent an unknown value " + tagged.keySet());
	}

	private static void authorize(String expected, String given) {
		if (expected == null || expected.isEmpty()) {
			return;
		}
		byte[] left = expected.getBytes(StandardCharsets.UTF_8);
		byte[] right = (given == null ? "" : given).getBytes(StandardCharsets.UTF_8);
		if (!MessageDigest.isEqual(left, right)) {
			throw new SecurityException("the invocation token is not valid");
		}
	}

	@SuppressWarnings("unchecked")
	private Map<String, Object> read() throws IOException {
		String line = in.readLine();
		if (line == null) {
			throw new IOException("connection closed");
		}
		return (Map<String, Object>) Json.parse(line);
	}

	private void send(Map<String, Object> message) throws IOException {
		out.write(Json.write(message));
		out.write('\n');
		out.flush();
	}
}
