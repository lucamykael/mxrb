package com.mendix.thirdparty.org.json;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Iterator;
import java.util.List;

/** A JSON array: an ordered sequence of JSON values. */
public class JSONArray implements Iterable<Object> {
	private final List<Object> list = new ArrayList<>();

	public JSONArray() {
	}

	public JSONArray(String source) {
		Object value = JSONValues.parse(source);
		if (!(value instanceof JSONArray array)) {
			throw new JSONException("a JSONArray text must begin with '['");
		}
		list.addAll(array.list);
	}

	public JSONArray(Collection<?> source) {
		if (source != null) {
			for (Object value : source) {
				list.add(JSONValues.wrap(value));
			}
		}
	}

	public JSONArray put(Object value) {
		list.add(JSONValues.wrap(value));
		return this;
	}

	public JSONArray put(boolean value) {
		return put((Object) value);
	}

	public JSONArray put(int value) {
		return put((Object) value);
	}

	public JSONArray put(long value) {
		return put((Object) value);
	}

	public JSONArray put(double value) {
		return put((Object) value);
	}

	public JSONArray put(int index, Object value) {
		while (list.size() <= index) {
			list.add(JSONObject.NULL);
		}
		list.set(index, JSONValues.wrap(value));
		return this;
	}

	public int length() {
		return list.size();
	}

	public boolean isEmpty() {
		return list.isEmpty();
	}

	public Object opt(int index) {
		return index < 0 || index >= list.size() ? null : list.get(index);
	}

	public Object get(int index) {
		Object value = opt(index);
		if (value == null) {
			throw new JSONException("JSONArray[" + index + "] not found.");
		}
		return value;
	}

	public boolean isNull(int index) {
		return JSONObject.NULL.equals(opt(index));
	}

	public Object remove(int index) {
		return index < 0 || index >= list.size() ? null : list.remove(index);
	}

	public String getString(int index) {
		Object value = get(index);
		if (value instanceof String string) {
			return string;
		}
		throw wrong(index, "a string");
	}

	public boolean getBoolean(int index) {
		Boolean value = bool(get(index));
		if (value == null) {
			throw wrong(index, "a boolean");
		}
		return value;
	}

	public int getInt(int index) {
		return number(index).intValue();
	}

	public long getLong(int index) {
		return number(index).longValue();
	}

	public double getDouble(int index) {
		return number(index).doubleValue();
	}

	public JSONObject getJSONObject(int index) {
		Object value = get(index);
		if (value instanceof JSONObject object) {
			return object;
		}
		throw wrong(index, "a JSONObject");
	}

	public JSONArray getJSONArray(int index) {
		Object value = get(index);
		if (value instanceof JSONArray array) {
			return array;
		}
		throw wrong(index, "a JSONArray");
	}

	public String optString(int index) {
		return optString(index, "");
	}

	public String optString(int index, String fallback) {
		Object value = opt(index);
		return value == null || JSONObject.NULL.equals(value) ? fallback : value.toString();
	}

	public int optInt(int index) {
		Number value = numeric(opt(index));
		return value == null ? 0 : value.intValue();
	}

	public long optLong(int index) {
		Number value = numeric(opt(index));
		return value == null ? 0L : value.longValue();
	}

	public boolean optBoolean(int index) {
		Boolean value = bool(opt(index));
		return value != null && value;
	}

	public JSONObject optJSONObject(int index) {
		return opt(index) instanceof JSONObject object ? object : null;
	}

	public JSONArray optJSONArray(int index) {
		return opt(index) instanceof JSONArray array ? array : null;
	}

	public List<Object> toList() {
		List<Object> result = new ArrayList<>();
		for (Object value : list) {
			result.add(unwrap(value));
		}
		return result;
	}

	@Override
	public Iterator<Object> iterator() {
		return list.iterator();
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
		out.append('[');
		for (int i = 0; i < list.size(); i++) {
			if (i > 0) {
				out.append(',');
			}
			JSONValues.newline(out, indent, depth + 1);
			JSONValues.write(list.get(i), out, indent, depth + 1);
		}
		if (!list.isEmpty()) {
			JSONValues.newline(out, indent, depth);
		}
		out.append(']');
	}

	static Boolean bool(Object value) {
		if (value instanceof Boolean flag) {
			return flag;
		}
		if (value instanceof String string && (string.equalsIgnoreCase("true") || string.equalsIgnoreCase("false"))) {
			return Boolean.valueOf(string);
		}
		return null;
	}

	static Number numeric(Object value) {
		if (value instanceof Number number) {
			return number;
		}
		if (value instanceof String string) {
			try {
				return new BigDecimal(string.trim());
			} catch (NumberFormatException e) {
				return null;
			}
		}
		return null;
	}

	static Object unwrap(Object value) {
		if (value instanceof JSONObject object) {
			return object.toMap();
		}
		if (value instanceof JSONArray array) {
			return array.toList();
		}
		return JSONObject.NULL.equals(value) ? null : value;
	}

	private Number number(int index) {
		Number value = numeric(get(index));
		if (value == null) {
			throw wrong(index, "a number");
		}
		return value;
	}

	private static JSONException wrong(int index, String kind) {
		return new JSONException("JSONArray[" + index + "] is not " + kind + ".");
	}
}
