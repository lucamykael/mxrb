package javax.servlet.http;

/** The parts of an HTTP response a request handler writes. */
public interface HttpServletResponse {
	void setStatus(int status);
	void setHeader(String name, String value);
	void addHeader(String name, String value);
	void setContentType(String type);
}
