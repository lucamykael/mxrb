package com.mendix.systemwideinterfaces.core;

/** The context of the microflow that calls a Java action. */
public interface IContext {
	ISession getSession();
	boolean isSudo();
	boolean isInTransaction();
	IContext createClone();
	IContext createSudoClone();
	void startTransaction();
	void endTransaction();
	void rollbackTransaction();

	/** The HTTP request of the action's context; the Ruby application does not hand it over. */
	default java.util.Optional<com.mendix.m2ee.api.IMxRuntimeRequest> getRuntimeRequest() {
		return java.util.Optional.empty();
	}

	default java.util.Optional<com.mendix.m2ee.api.IMxRuntimeResponse> getRuntimeResponse() {
		return java.util.Optional.empty();
	}

	/** The name older Runtime versions gave rollbackTransaction. */
	default void rollbackTransAction() {
		rollbackTransaction();
	}
	IMendixObject getCurrentUserObject();
}
