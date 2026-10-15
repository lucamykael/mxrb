package mxrb.sidecar;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.servlet.http.HttpServletRequest;

import com.mendix.m2ee.api.IMxRuntimeRequest;

/** A request the Ruby application's server forwards to a request handler. */
public final class MxRuntimeRequest implements IMxRuntimeRequest, HttpServletRequest {
	private final String method;
	private final String path;
	private final String handler;
	private final String query;
	private final String rootUrl;
	private final String remoteAddress;
	private final Map<String, String> headers = new LinkedHashMap<>();
	private final Map<String, String> cookies = new LinkedHashMap<>();
	private final Map<String, String> parameters = new LinkedHashMap<>();
	private final byte[] body;
	private final MxSession session;

	@SuppressWarnings("unchecked")
	MxRuntimeRequest(Map<String, Object> request, String handler, MxSession session) {
		this.method = (String) request.get("method");
		this.path = (String) request.get("path");
		this.handler = handler;
		this.query = (String) request.get("query");
		this.rootUrl = (String) request.get("root_url");
		this.remoteAddress = (String) request.get("remote_addr");
		((Map<String, Object>) request.get("headers")).forEach((name, value) -> headers.put(name.toLowerCase(), (String) value));
		((Map<String, Object>) request.get("cookies")).forEach((name, value) -> cookies.put(name, (String) value));
		this.body = (byte[]) request.get("body");
		this.session = session;
		if (query != null) {
			for (String pair : query.split("&")) {
				if (!pair.isEmpty()) {
					int equals = pair.indexOf('=');
					String name = decode(equals < 0 ? pair : pair.substring(0, equals));
					parameters.putIfAbsent(name, equals < 0 ? "" : decode(pair.substring(equals + 1)));
				}
			}
		}
	}

	public MxSession session() {
		return session;
	}

	private static String decode(String value) {
		return URLDecoder.decode(value, StandardCharsets.UTF_8);
	}

	@Override
	public String getRequestString() {
		return path + (query == null || query.isEmpty() ? "" : "?" + query);
	}

	@Override
	public String getParameter(String name) {
		return parameters.get(name);
	}

	@Override
	public javax.servlet.http.Cookie[] getCookies() {
		if (cookies.isEmpty()) {
			return null;
		}
		return cookies.entrySet().stream().map(cookie -> new javax.servlet.http.Cookie(cookie.getKey(), cookie.getValue()))
				.toArray(javax.servlet.http.Cookie[]::new);
	}

	@Override
	public String getCookie(String name) {
		return cookies.get(name);
	}

	@Override
	public String getRemoteAddr() {
		return remoteAddress;
	}

	@Override
	public InputStream getInputStream() {
		return new ByteArrayInputStream(body == null ? new byte[0] : body);
	}

	/** The request's path from the application root, such as "/link/order/1". */
	@Override
	public String getResourcePath() {
		return path;
	}

	/** What follows the handler's path, without slashes around it: "order/1" for "/link/order/1". */
	String handlerPath() {
		String info = getPathInfo();
		return info == null ? "" : info.replaceAll("^/+|/+$", "");
	}

	@Override
	public String getRootUrl() {
		return rootUrl;
	}

	@Override
	public String getHeader(String name) {
		return headers.get(name.toLowerCase());
	}

	@Override
	public Enumeration<String> getHeaderNames() {
		return Collections.enumeration(List.copyOf(headers.keySet()));
	}

	@Override
	public HttpServletRequest getHttpServletRequest() {
		return this;
	}

	@Override
	public String getMethod() {
		return method;
	}

	@Override
	public String getRequestURI() {
		return path;
	}

	@Override
	public StringBuffer getRequestURL() {
		String root = rootUrl.endsWith("/") ? rootUrl.substring(0, rootUrl.length() - 1) : rootUrl;
		return new StringBuffer(root + path);
	}

	@Override
	public String getContextPath() {
		return "";
	}

	/** The handler's path, as a servlet mapped to it reports it. */
	@Override
	public String getServletPath() {
		return "/" + handler.replaceAll("^/|/$", "");
	}

	/** What follows the handler's path. */
	@Override
	public String getPathInfo() {
		String servlet = getServletPath();
		return path.startsWith(servlet) && path.length() > servlet.length() ? path.substring(servlet.length()) : null;
	}

	@Override
	public String getQueryString() {
		return query == null || query.isEmpty() ? null : query;
	}

	@Override
	public String getScheme() {
		return java.net.URI.create(rootUrl).getScheme();
	}

	@Override
	public String getServerName() {
		return java.net.URI.create(rootUrl).getHost();
	}

	@Override
	public int getServerPort() {
		java.net.URI uri = java.net.URI.create(rootUrl);
		return uri.getPort() > 0 ? uri.getPort() : "https".equals(uri.getScheme()) ? 443 : 80;
	}
}
