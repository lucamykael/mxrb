package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type String of an object. */
public class MendixString extends MendixObjectMember<String> {
	public MendixString(IMendixObject object, String name) {
		super(object, name);
	}
}
