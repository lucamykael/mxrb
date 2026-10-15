package com.mendix.webui;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.UserAction;

/** The base class Studio Pro generates Java actions from. */
public abstract class CustomJavaAction<R> extends UserAction<R> {
	public CustomJavaAction(IContext context) {
		super(context);
	}
}
