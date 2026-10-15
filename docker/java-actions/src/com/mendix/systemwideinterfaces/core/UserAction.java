package com.mendix.systemwideinterfaces.core;

/** A Java action: the Runtime constructs it with its parameters and executes it. */
public abstract class UserAction<R> {
	private final IContext context;

	public UserAction(IContext context) {
		this.context = context;
	}

	public IContext getContext() {
		return context;
	}

	/** The context the action runs in, as newer Studio Pro versions name it. */
	public IContext context() {
		return context;
	}

	public R execute() throws Exception {
		return executeAction();
	}

	public abstract R executeAction() throws Exception;
}
