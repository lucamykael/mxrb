package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type BigDecimal of an object. */
public class MendixDecimal extends MendixObjectMember<java.math.BigDecimal> {
	public MendixDecimal(IMendixObject object, String name) {
		super(object, name);
	}
}
