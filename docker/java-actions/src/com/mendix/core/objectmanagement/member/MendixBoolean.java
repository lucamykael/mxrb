package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type Boolean of an object. */
public class MendixBoolean extends MendixObjectMember<Boolean> {
	public MendixBoolean(IMendixObject object, String name) {
		super(object, name);
	}
}
