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

	/** The name older Runtime versions gave rollbackTransaction. */
	default void rollbackTransAction() {
		rollbackTransaction();
	}
	IMendixObject getCurrentUserObject();
}
