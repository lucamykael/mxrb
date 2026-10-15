package javax.servlet.http;

/** The parts of an HTTP response a request handler writes. */
public interface HttpServletResponse {
	int SC_OK = 200;
	int SC_CREATED = 201;
	int SC_NO_CONTENT = 204;
	int SC_MOVED_PERMANENTLY = 301;
	int SC_FOUND = 302;
	int SC_SEE_OTHER = 303;
	int SC_NOT_MODIFIED = 304;
	int SC_BAD_REQUEST = 400;
	int SC_UNAUTHORIZED = 401;
	int SC_FORBIDDEN = 403;
	int SC_NOT_FOUND = 404;
	int SC_METHOD_NOT_ALLOWED = 405;
	int SC_CONFLICT = 409;
	int SC_INTERNAL_SERVER_ERROR = 500;
	int SC_SERVICE_UNAVAILABLE = 503;

	void setStatus(int status);
	void setHeader(String name, String value);
	void addHeader(String name, String value);
	void addCookie(Cookie cookie);
	void setContentType(String type);
	java.io.OutputStream getOutputStream() throws java.io.IOException;
}
