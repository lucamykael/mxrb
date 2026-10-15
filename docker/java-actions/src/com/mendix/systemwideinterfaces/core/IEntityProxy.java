package com.mendix.systemwideinterfaces.core;

import com.mendix.core.Core;
import com.mendix.core.CoreException;

/** A generated proxy of an entity: a typed view of one object. */
public interface IEntityProxy {
	IMendixObject getMendixObject();

	IContext getContext();

	default void commit() throws CoreException {
		commit(getContext());
	}

	default void commit(IContext context) throws CoreException {
		Core.commit(context, getMendixObject());
	}

	default void delete() {
		delete(getContext());
	}

	default void delete(IContext context) {
		Core.delete(context, getMendixObject());
	}
}
