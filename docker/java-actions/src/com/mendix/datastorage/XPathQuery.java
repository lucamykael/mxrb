package com.mendix.datastorage;

import java.math.BigDecimal;
import java.util.Date;
import java.util.List;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** An XPath retrieve with variables, a range and sortings, as Core.createXPathQuery makes it. */
public interface XPathQuery extends XPathBasicQuery {
	@Override
	XPathQuery setAmount(int amount);
	@Override
	XPathQuery setOffset(int offset);
	@Override
	XPathQuery addSort(String path, boolean ascending);
	@Override
	XPathQuery setDepth(int depth);
	@Override
	XPathQuery setVariable(String name, BigDecimal value);
	@Override
	XPathQuery setVariable(String name, boolean value);
	@Override
	XPathQuery setVariable(String name, double value);
	@Override
	XPathQuery setVariable(String name, int value);
	@Override
	XPathQuery setVariable(String name, long value);
	@Override
	XPathQuery setVariable(String name, IMendixObject value);
	@Override
	XPathQuery setVariable(String name, IMendixIdentifier value);
	@Override
	XPathQuery setVariable(String name, String value);
	@Override
	XPathQuery setVariable(String name, Date value);
	@Override
	List<IMendixObject> execute(IContext context);
}
