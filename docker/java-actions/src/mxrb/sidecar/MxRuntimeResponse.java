package mxrb.sidecar;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.Writer;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.servlet.http.HttpServletResponse;

import com.mendix.m2ee.api.IMxRuntimeResponse;

/** The response a request handler writes, which the Ruby application's server sends. */
public final class MxRuntimeResponse implements IMxRuntimeResponse, HttpServletResponse {
	private final ByteArrayOutputStream body = new ByteArrayOutputStream();
	private final List<Object> headers = new ArrayList<>();
	private final List<Object> cookies = new ArrayList<>();
	private int status = OK;
	private String contentType;
	private String encoding = "UTF-8";
	private PrintWriter writer;

	@Override
	public String getContentType() {
		return contentType;
	}

	@Override
	public String getCharacterEncoding() {
		return encoding;
	}

	@Override
	public void setContentType(String type) {
		this.contentType = type;
	}

	@Override
	public void setCharacterEncoding(String encoding) {
		this.encoding = encoding;
	}

	@Override
	public Writer getWriter() {
		if (writer == null) {
			writer = new PrintWriter(new OutputStreamWriter(body, Charset.forName(encoding)));
		}
		return writer;
	}

	@Override
	public OutputStream getOutputStream() {
		return body;
	}

	@Override
	public void sendError(String message) {
		status = INTERNAL_SERVER_ERROR;
		getWriter();
		writer.write(message);
	}

	@Override
	public void setStatus(int status) {
		this.status = status;
	}

	@Override
	public void setHeader(String name, String value) {
		headers.removeIf(header -> ((List<?>) header).get(0).toString().equalsIgnoreCase(name));
		addHeader(name, value);
	}

	/** A header without a value is not sent, as a servlet container leaves it out. */
	@Override
	public void addHeader(String name, String value) {
		if (value != null) {
			headers.add(List.of(name, value));
		}
	}

	@Override
	public void addCookie(String name, String value, String path, String domain, int expiry, boolean httpOnly) {
		Map<String, Object> cookie = new LinkedHashMap<>();
		cookie.put("name", name);
		cookie.put("value", value);
		cookie.put("path", path);
		cookie.put("max_age", (long) expiry);
		cookie.put("http_only", httpOnly);
		cookies.add(cookie);
	}

	@Override
	public HttpServletResponse getHttpServletResponse() {
		return this;
	}

	/** The response as the Ruby application's server sends it. */
	Map<String, Object> result() {
		if (writer != null) {
			writer.flush();
		}
		Map<String, Object> result = new LinkedHashMap<>();
		result.put("status", (long) status);
		result.put("content_type", contentType);
		result.put("headers", headers);
		result.put("cookies", cookies);
		result.put("body", body.toByteArray());
		return result;
	}
}
