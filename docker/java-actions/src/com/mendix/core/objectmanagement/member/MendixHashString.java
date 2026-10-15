package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type String of an object. */
public class MendixHashString extends MendixObjectMember<String> {
	public MendixHashString(IMendixObject object, String name) {
		super(object, name);
	}
}
