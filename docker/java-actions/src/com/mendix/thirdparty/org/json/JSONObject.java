package com.mendix.thirdparty.org.json;

import java.math.BigDecimal;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** A JSON object: names in insertion order, values that are JSON values. */
public class JSONObject {
	/** JSON's null, which a JSONObject holds where Java has none. */
	public static final Object NULL = new Object() {
		@Override
		public boolean equals(Object other) {
			return other == null || other == this;
		}

		@Override
		public int hashCode() {
			return 0;
		}

		@Override
		public String toString() {
			return "null";
		}
	};

	private final Map<String, Object> map = new LinkedHashMap<>();

	public JSONObject() {
	}

	public JSONObject(String source) {
		Object value = JSONValues.parse(source);
		if (!(value instanceof JSONObject object)) {
			throw new JSONException("a JSONObject text must begin with '{'");
		}
		map.putAll(object.map);
	}

	public JSONObject(Map<?, ?> source) {
		if (source != null) {
			source.forEach((key, value) -> {
				if (value != null) {
					map.put(String.valueOf(key), JSONValues.wrap(value));
				}
			});
		}
	}

	public JSONObject put(String key, Object value) {
		if (key == null) {
			throw new NullPointerException("null key");
		}
		if (value == null) {
			map.remove(key);
		} else {
			map.put(key, JSONValues.wrap(value));
		}
		return this;
	}

	public JSONObject put(String key, boolean value) {
		return put(key, (Object) value);
	}

	public JSONObject put(String key, int value) {
		return put(key, (Object) value);
	}

	public JSONObject put(String key, long value) {
		return put(key, (Object) value);
	}

	public JSONObject put(String key, double value) {
		return put(key, (Object) value);
	}

	public Object opt(String key) {
		return key == null ? null : map.get(key);
	}

	public Object get(String key) {
		Object value = opt(key);
		if (value == null) {
			throw new JSONException("JSONObject[" + JSONObject.quote(key) + "] not found.");
		}
		return value;
	}

	public boolean has(String key) {
		return map.containsKey(key);
	}

	public boolean isNull(String key) {
		return NULL.equals(opt(key));
	}

	public Object remove(String key) {
		return map.remove(key);
	}

	public int length() {
		return map.size();
	}

	public boolean isEmpty() {
		return map.isEmpty();
	}

	public Set<String> keySet() {
		return map.keySet();
	}

	public Iterator<String> keys() {
		return map.keySet().iterator();
	}

	public JSONArray names() {
		return map.isEmpty() ? null : new JSONArray(map.keySet());
	}

	public String getString(String key) {
		Object value = get(key);
		if (value instanceof String string) {
			return string;
		}
		throw wrong(key, "a string");
	}

	public boolean getBoolean(String key) {
		Object value = get(key);
		Boolean result = JSONArray.bool(value);
		if (result == null) {
			throw wrong(key, "a boolean");
		}
		return result;
	}

	public int getInt(String key) {
		return number(key).intValue();
	}

	public long getLong(String key) {
		return number(key).longValue();
	}

	public double getDouble(String key) {
		return number(key).doubleValue();
	}

	public BigDecimal getBigDecimal(String key) {
		return new BigDecimal(JSONValues.number(number(key)));
	}

	public JSONObject getJSONObject(String key) {
		Object value = get(key);
		if (value instanceof JSONObject object) {
			return object;
		}
		throw wrong(key, "a JSONObject");
	}

	public JSONArray getJSONArray(String key) {
		Object value = get(key);
		if (value instanceof JSONArray array) {
			return array;
		}
		throw wrong(key, "a JSONArray");
	}

	public String optString(String key) {
		return optString(key, "");
	}

	public String optString(String key, String fallback) {
		Object value = opt(key);
		return value == null || NULL.equals(value) ? fallback : value.toString();
	}

	public boolean optBoolean(String key) {
		return optBoolean(key, false);
	}

	public boolean optBoolean(String key, boolean fallback) {
		Boolean value = JSONArray.bool(opt(key));
		return value == null ? fallback : value;
	}

	public int optInt(String key) {
		return optInt(key, 0);
	}

	public int optInt(String key, int fallback) {
		Number value = JSONArray.numeric(opt(key));
		return value == null ? fallback : value.intValue();
	}

	public long optLong(String key) {
		return optLong(key, 0L);
	}

	public long optLong(String key, long fallback) {
		Number value = JSONArray.numeric(opt(key));
		return value == null ? fallback : value.longValue();
	}

	public double optDouble(String key) {
		return optDouble(key, Double.NaN);
	}

	public double optDouble(String key, double fallback) {
		Number value = JSONArray.numeric(opt(key));
		return value == null ? fallback : value.doubleValue();
	}

	public JSONObject optJSONObject(String key) {
		return opt(key) instanceof JSONObject object ? object : null;
	}

	public JSONArray optJSONArray(String key) {
		return opt(key) instanceof JSONArray array ? array : null;
	}

	public Map<String, Object> toMap() {
		Map<String, Object> result = new LinkedHashMap<>();
		map.forEach((key, value) -> result.put(key, JSONArray.unwrap(value)));
		return result;
	}

	public static String quote(String value) {
		StringBuilder out = new StringBuilder();
		JSONValues.quote(value == null ? "" : value, out);
		return out.toString();
	}

	@Override
	public String toString() {
		return toString(0);
	}

	public String toString(int indent) {
		StringBuilder out = new StringBuilder();
		write(out, indent, 0);
		return out.toString();
	}

	void write(StringBuilder out, int indent, int depth) {
		out.append('{');
		boolean first = true;
		for (Map.Entry<String, Object> entry : map.entrySet()) {
			if (!first) {
				out.append(',');
			}
			first = false;
			JSONValues.newline(out, indent, depth + 1);
			JSONValues.quote(entry.getKey(), out);
			out.append(indent > 0 ? ": " : ":");
			JSONValues.write(entry.getValue(), out, indent, depth + 1);
		}
		if (!map.isEmpty()) {
			JSONValues.newline(out, indent, depth);
		}
		out.append('}');
	}

	private Number number(String key) {
		Number value = JSONArray.numeric(get(key));
		if (value == null) {
			throw wrong(key, "a number");
		}
		return value;
	}

	private static JSONException wrong(String key, String kind) {
		return new JSONException("JSONObject[" + quote(key) + "] is not " + kind + ".");
	}
}
