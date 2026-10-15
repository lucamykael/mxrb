package com.mendix.systemwideinterfaces.core;

/** A member of an object: an attribute or an association, with its value. */
public interface IMendixObjectMember<T> {
	/** Whether the member changed since the object was last committed. */
	enum MemberState { UNCHANGED, CHANGED }

	T getValue(IContext context);
	void setValue(IContext context, T value);
	String parseValueToString(IContext context);
	boolean isVirtual();
	T getOriginalValue(IContext context);
	MemberState getState();
	String getName();
	boolean isChanged();

	default boolean isValueChanged(IContext context) {
		return isChanged();
	}
}
