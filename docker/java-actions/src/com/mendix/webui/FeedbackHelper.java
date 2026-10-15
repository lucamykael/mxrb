package com.mendix.webui;

import java.util.List;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IFeedback;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;

import mxrb.sidecar.MxContext;

/**
 * Client feedback from a Java action. A message becomes the calling
 * microflow's show-message effect; the Ruby application's client refreshes
 * data on its own, so refresh requests need nothing.
 */
public class FeedbackHelper {
	public static void addTextMessageFeedback(IContext context, IFeedback.MessageType type, String message,
			boolean blocking) {
		((MxContext) context).bridge().call("message", "type", type.name(), "message", message, "blocking", blocking);
	}

	public static void addRefreshObjectFeedback(IContext context, IMendixIdentifier id) {
	}

	public static void addRefreshObjectListFeedback(IContext context, List<IMendixIdentifier> ids) {
	}

	public static void addRefreshClass(IContext context, String entity) {
	}
}
