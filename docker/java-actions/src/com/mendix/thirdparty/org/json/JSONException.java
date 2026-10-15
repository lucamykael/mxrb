package com.mendix.thirdparty.org.json;

/** A JSON text that does not parse, or a value of another type than asked. */
public class JSONException extends RuntimeException {
	private static final long serialVersionUID = 1L;

	public JSONException(String message) {
		super(message);
	}

	public JSONException(String message, Throwable cause) {
		super(message, cause);
	}
}
