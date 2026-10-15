package mxrb.sidecar;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** The JSON of the protocol: objects, arrays, strings, integers, booleans and null. */
public final class Json {
	private final String text;
	private int position;

	private Json(String text) {
		this.text = text;
	}

	public static Object parse(String text) {
		Json json = new Json(text);
		Object value = json.value();
		json.whitespace();
		if (json.position != text.length()) {
			throw json.error("trailing characters");
		}
		return value;
	}

	public static String write(Object value) {
		StringBuilder out = new StringBuilder();
		write(value, out);
		return out.toString();
	}

	private static void write(Object value, StringBuilder out) {
		if (value == null) {
			out.append("null");
		} else if (value instanceof String string) {
			string(string, out);
		} else if (value instanceof Boolean || value instanceof Long || value instanceof Integer) {
			out.append(value);
		} else if (value instanceof Map<?, ?> map) {
			out.append('{');
			boolean first = true;
			for (Map.Entry<?, ?> entry : map.entrySet()) {
				if (!first) {
					out.append(',');
				}
				first = false;
				string(String.valueOf(entry.getKey()), out);
				out.append(':');
				write(entry.getValue(), out);
			}
			out.append('}');
		} else if (value instanceof Collection<?> list) {
			out.append('[');
			boolean first = true;
			for (Object item : list) {
				if (!first) {
					out.append(',');
				}
				first = false;
				write(item, out);
			}
			out.append(']');
		} else {
			throw new IllegalArgumentException("cannot write " + value.getClass().getName() + " as JSON");
		}
	}

	private static void string(String value, StringBuilder out) {
		out.append('"');
		for (int i = 0; i < value.length(); i++) {
			char c = value.charAt(i);
			switch (c) {
			case '"' -> out.append("\\\"");
			case '\\' -> out.append("\\\\");
			case '\n' -> out.append("\\n");
			case '\r' -> out.append("\\r");
			case '\t' -> out.append("\\t");
			default -> {
				if (c < 0x20) {
					out.append(String.format("\\u%04x", (int) c));
				} else {
					out.append(c);
				}
			}
			}
		}
		out.append('"');
	}

	private Object value() {
		whitespace();
		if (position >= text.length()) {
			throw error("unexpected end");
		}
		char c = text.charAt(position);
		switch (c) {
		case '{':
			return object();
		case '[':
			return array();
		case '"':
			return string();
		case 't':
			return literal("true", Boolean.TRUE);
		case 'f':
			return literal("false", Boolean.FALSE);
		case 'n':
			return literal("null", null);
		default:
			return number();
		}
	}

	private Map<String, Object> object() {
		Map<String, Object> map = new LinkedHashMap<>();
		position++;
		whitespace();
		if (peek('}')) {
			position++;
			return map;
		}
		while (true) {
			whitespace();
			String key = string();
			whitespace();
			expect(':');
			map.put(key, value());
			whitespace();
			if (peek(',')) {
				position++;
			} else {
				expect('}');
				return map;
			}
		}
	}

	private List<Object> array() {
		List<Object> list = new ArrayList<>();
		position++;
		whitespace();
		if (peek(']')) {
			position++;
			return list;
		}
		while (true) {
			list.add(value());
			whitespace();
			if (peek(',')) {
				position++;
			} else {
				expect(']');
				return list;
			}
		}
	}

	private String string() {
		expect('"');
		StringBuilder out = new StringBuilder();
		while (true) {
			if (position >= text.length()) {
				throw error("unterminated string");
			}
			char c = text.charAt(position++);
			if (c == '"') {
				return out.toString();
			}
			if (c != '\\') {
				out.append(c);
				continue;
			}
			char escape = text.charAt(position++);
			switch (escape) {
			case 'b' -> out.append('\b');
			case 'f' -> out.append('\f');
			case 'n' -> out.append('\n');
			case 'r' -> out.append('\r');
			case 't' -> out.append('\t');
			case 'u' -> {
				out.append((char) Integer.parseInt(text.substring(position, position + 4), 16));
				position += 4;
			}
			default -> out.append(escape);
			}
		}
	}

	private Object number() {
		int start = position;
		while (position < text.length() && "+-0123456789.eE".indexOf(text.charAt(position)) >= 0) {
			position++;
		}
		String number = text.substring(start, position);
		if (number.isEmpty()) {
			throw error("unexpected character");
		}
		if (number.matches("-?\\d+")) {
			return Long.parseLong(number);
		}
		return new java.math.BigDecimal(number);
	}

	private Object literal(String word, Object value) {
		if (!text.startsWith(word, position)) {
			throw error("unexpected literal");
		}
		position += word.length();
		return value;
	}

	private void whitespace() {
		while (position < text.length() && Character.isWhitespace(text.charAt(position))) {
			position++;
		}
	}

	private boolean peek(char c) {
		return position < text.length() && text.charAt(position) == c;
	}

	private void expect(char c) {
		if (!peek(c)) {
			throw error("expected '" + c + "'");
		}
		position++;
	}

	private IllegalArgumentException error(String message) {
		return new IllegalArgumentException("malformed JSON at " + position + ": " + message);
	}
}
