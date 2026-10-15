package javax.servlet.http;

/** The parts of an HTTP request a request handler reads. */
public interface HttpServletRequest {
	String getMethod();
	String getRequestURI();
	StringBuffer getRequestURL();
	String getContextPath();
	String getServletPath();
	String getPathInfo();
	String getQueryString();
	String getScheme();
	String getServerName();
	int getServerPort();
	String getRemoteAddr();
	String getHeader(String name);
	String getParameter(String name);
	/** The request's cookies, or null when it has none. */
	Cookie[] getCookies();
	java.io.InputStream getInputStream() throws java.io.IOException;
}
