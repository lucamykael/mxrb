package com.mendix.m2ee.api;

import java.io.IOException;
import java.io.OutputStream;
import java.io.Writer;

import javax.servlet.http.HttpServletResponse;

/** The response of a request handler. */
public interface IMxRuntimeResponse {
	int OK = 200;
	int SEE_OTHER = 303;
	int NOT_MODIFIED = 304;
	int BAD_REQUEST = 400;
	int UNAUTHORIZED = 401;
	int NEED_PAYMENT = 402;
	int FORBIDDEN = 403;
	int NOT_FOUND = 404;
	int METHOD_NOT_ALLOWED = 405;
	int CONFLICT = 409;
	int TOO_MANY_REQUESTS = 429;
	int SESSION_KILLED = 440;
	int INTERNAL_SERVER_ERROR = 500;
	int SERVICE_UNAVAILABLE = 503;

	String getContentType();
	String getCharacterEncoding();
	void setContentType(String type);
	void setCharacterEncoding(String encoding);
	Writer getWriter() throws IOException;
	OutputStream getOutputStream() throws IOException;
	void sendError(String message);
	void setStatus(int status);
	void addHeader(String name, String value);
	void addCookie(String name, String value, String path, String domain, int expiry, boolean httpOnly);
	HttpServletResponse getHttpServletResponse();

	default void addCookie(String name, String value, boolean httpOnly) {
		addCookie(name, value, "/", "", -1, httpOnly);
	}

	default void addCookie(String name, String value, String path, String domain, int expiry) {
		addCookie(name, value, path, domain, expiry, true);
	}

	default void addCookie(String name, String value, String path, String domain, int expiry, boolean httpOnly,
			boolean secure) {
		addCookie(name, value, path, domain, expiry, httpOnly);
	}
}
