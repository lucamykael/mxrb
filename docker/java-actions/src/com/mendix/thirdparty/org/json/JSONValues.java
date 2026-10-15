package com.mendix.thirdparty.org.json;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Collection;
import java.util.Map;

/** Parsing and writing JSON text for JSONObject and JSONArray. */
final class JSONValues {
	private final String text;
	private int position;

	private JSONValues(String text) {
		this.text = text;
	}

	static Object parse(String text) {
		JSONValues values = new JSONValues(text);
		Object value = values.value();
		values.whitespace();
		if (values.position != text.length()) {
			throw values.error("unexpected text after the value");
		}
		return value;
	}

	/** A value as JSONObject and JSONArray hold it: maps and collections wrapped, null as NULL. */
	static Object wrap(Object value) {
		if (value == null) {
			return JSONObject.NULL;
		}
		if (value instanceof JSONObject || value instanceof JSONArray || value == JSONObject.NULL
				|| value instanceof String || value instanceof Number || value instanceof Boolean
				|| value instanceof Character) {
			return value;
		}
		if (value instanceof Map<?, ?> map) {
			return new JSONObject(map);
		}
		if (value instanceof Collection<?> collection) {
			return new JSONArray(collection);
		}
		if (value.getClass().isArray()) {
			JSONArray array = new JSONArray();
			for (int i = 0; i < java.lang.reflect.Array.getLength(value); i++) {
				array.put(java.lang.reflect.Array.get(value, i));
			}
			return array;
		}
		if (value instanceof Enum<?> constant) {
			return constant.name();
		}
		return value.toString();
	}

	static void write(Object value, StringBuilder out, int indent, int depth) {
		if (value == null || value == JSONObject.NULL) {
			out.append("null");
		} else if (value instanceof JSONObject object) {
			object.write(out, indent, depth);
		} else if (value instanceof JSONArray array) {
			array.write(out, indent, depth);
		} else if (value instanceof Number number) {
			out.append(number(number));
		} else if (value instanceof Boolean) {
			out.append(value);
		} else {
			quote(value.toString(), out);
		}
	}

	static String number(Number number) {
		if (number instanceof Double || number instanceof Float) {
			double value = number.doubleValue();
			if (Double.isNaN(value) || Double.isInfinite(value)) {
				throw new JSONException("JSON does not allow non-finite numbers");
			}
			if (value == Math.rint(value) && Math.abs(value) < 1e15) {
				return Long.toString((long) value);
			}
		}
		if (number instanceof BigDecimal decimal) {
			return decimal.stripTrailingZeros().toPlainString();
		}
		return number.toString();
	}

	static void quote(String value, StringBuilder out) {
		out.append('"');
		for (int i = 0; i < value.length(); i++) {
			char c = value.charAt(i);
			switch (c) {
			case '"' -> out.append("\\\"");
			case '\\' -> out.append("\\\\");
			case '\n' -> out.append("\\n");
			case '\r' -> out.append("\\r");
			case '\t' -> out.append("\\t");
			case '\b' -> out.append("\\b");
			case '\f' -> out.append("\\f");
			case '/' -> out.append(i > 0 && value.charAt(i - 1) == '<' ? "\\/" : "/");
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

	static void newline(StringBuilder out, int indent, int depth) {
		if (indent > 0) {
			out.append('\n');
			out.append(" ".repeat(indent * depth));
		}
	}

	private Object value() {
		whitespace();
		if (position >= text.length()) {
			throw error("a value is missing");
		}
		char c = text.charAt(position);
		if (c == '{') {
			return object();
		}
		if (c == '[') {
			return array();
		}
		if (c == '"' || c == '\'') {
			return string();
		}
		return literal();
	}

	private JSONObject object() {
		JSONObject object = new JSONObject();
		position++;
		whitespace();
		if (peek('}')) {
			position++;
			return object;
		}
		while (true) {
			whitespace();
			Object key = value();
			whitespace();
			expect(':');
			object.put(key.toString(), value());
			whitespace();
			if (peek(',')) {
				position++;
			} else {
				expect('}');
				return object;
			}
		}
	}

	private JSONArray array() {
		JSONArray array = new JSONArray();
		position++;
		whitespace();
		if (peek(']')) {
			position++;
			return array;
		}
		while (true) {
			array.put(value());
			whitespace();
			if (peek(',')) {
				position++;
			} else {
				expect(']');
				return array;
			}
		}
	}

	private String string() {
		char quote = text.charAt(position++);
		StringBuilder out = new StringBuilder();
		while (true) {
			if (position >= text.length()) {
				throw error("an unterminated string");
			}
			char c = text.charAt(position++);
			if (c == quote) {
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

	/** true, false, null, a number, or an unquoted word as org.json reads it. */
	private Object literal() {
		int start = position;
		while (position < text.length() && ",:]}/\\\"[{;=#".indexOf(text.charAt(position)) < 0
				&& !Character.isWhitespace(text.charAt(position))) {
			position++;
		}
		String word = text.substring(start, position);
		if (word.isEmpty()) {
			throw error("a value is missing");
		}
		switch (word) {
		case "true":
			return Boolean.TRUE;
		case "false":
			return Boolean.FALSE;
		case "null":
			return JSONObject.NULL;
		default:
			return number(word);
		}
	}

	private static Object number(String word) {
		if (!word.matches("-?(\\d+)(\\.\\d+)?([eE][+-]?\\d+)?")) {
			return word;
		}
		if (word.matches("-?\\d+")) {
			BigInteger value = new BigInteger(word);
			if (value.bitLength() < 32) {
				return value.intValue();
			}
			return value.bitLength() < 64 ? (Object) value.longValue() : value;
		}
		BigDecimal decimal = new BigDecimal(word);
		double value = decimal.doubleValue();
		return !Double.isInfinite(value) && new BigDecimal(Double.toString(value)).compareTo(decimal) == 0 ? value
				: decimal;
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

	private JSONException error(String message) {
		return new JSONException(message + " at character " + position);
	}
}
