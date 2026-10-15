package com.mendix.externalinterface.connector;

import com.mendix.core.Core;
import com.mendix.logging.ILogNode;
import com.mendix.m2ee.api.IMxRuntimeRequest;
import com.mendix.m2ee.api.IMxRuntimeResponse;
import com.mendix.systemwideinterfaces.core.ISession;

import mxrb.sidecar.MxRuntimeRequest;

/**
 * A handler of the requests to a path of the application, which
 * Core.addRequestHandler registers; the Ruby application's server forwards them.
 */
public abstract class RequestHandler {
	protected ILogNode logger = Core.getLogger(getClass().getSimpleName());

	public void doProcessRequest(IMxRuntimeRequest request, IMxRuntimeResponse response, String path)
			throws Exception {
		processRequest(request, response, path);
	}

	protected abstract void processRequest(IMxRuntimeRequest request, IMxRuntimeResponse response, String path)
			throws Exception;

	/** The session of the request's cookie, or null for a request without one. */
	protected ISession getSessionFromRequest(IMxRuntimeRequest request) {
		return ((MxRuntimeRequest) request).session();
	}

	protected ISession getSessionFromRequest(IMxRuntimeRequest request, boolean extend) {
		return getSessionFromRequest(request);
	}

	protected String getSessionCookieName() {
		return Core.getConfiguration().getSessionIdCookieName();
	}
}
