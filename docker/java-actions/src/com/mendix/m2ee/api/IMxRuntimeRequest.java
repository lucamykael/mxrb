package com.mendix.m2ee.api;

import java.io.IOException;
import java.io.InputStream;

import javax.servlet.http.HttpServletRequest;

/** A request to a request handler of the application. */
public interface IMxRuntimeRequest {
	String getRequestString();
	String getParameter(String name);
	String getCookie(String name);
	String getRemoteAddr();
	InputStream getInputStream() throws IOException;
	String getResourcePath();
	String getRootUrl();
	String getHeader(String name);
	java.util.Enumeration<String> getHeaderNames();
	HttpServletRequest getHttpServletRequest();
}
