package com.mendix.systemwideinterfaces.core;

/** An object of an entity, read and changed in the Ruby application's transaction. */
public interface IMendixObject {
	String getType();
	void setValue(IContext context, String member, Object value);
	<T> T getValue(IContext context, String member);
	boolean hasMember(String member);
	IMendixIdentifier getId();
	boolean isChanged();
	boolean equals(Object other);
	int hashCode();

	default boolean isInstanceOf(String entity) {
		return getType().equals(entity);
	}
}
