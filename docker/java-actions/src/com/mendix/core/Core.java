package com.mendix.core;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import com.mendix.core.actionmanagement.MicroflowCallBuilder;
import com.mendix.core.conf.Configuration;
import com.mendix.datastorage.XPathQuery;
import com.mendix.logging.ILogNode;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

import mxrb.sidecar.Bridge;
import mxrb.sidecar.MxContext;
import mxrb.sidecar.MxLogNode;
import mxrb.sidecar.MxMicroflowCall;
import mxrb.sidecar.MxXPathQuery;

/** The Runtime API of the Ruby application, reached through the invocation's bridge. */
public final class Core {
	private Core() {
	}

	public static ILogNode getLogger(String name) {
		return new MxLogNode(name);
	}

	public static IMendixObject instantiate(IContext context, String entity) {
		return (IMendixObject) bridge(context).call("instantiate", "entity", entity);
	}

	public static IMendixObject commit(IContext context, IMendixObject object) throws CoreException {
		store(context, "commit", List.of(object), true);
		return object;
	}

	public static List<IMendixObject> commit(IContext context, List<IMendixObject> objects) {
		store(context, "commit", objects, true);
		return objects;
	}

	public static IMendixObject commitWithoutEvents(IContext context, IMendixObject object) {
		store(context, "commit", List.of(object), false);
		return object;
	}

	public static List<IMendixObject> commitWithoutEvents(IContext context, List<IMendixObject> objects) {
		store(context, "commit", objects, false);
		return objects;
	}

	public static boolean delete(IContext context, IMendixObject... objects) {
		store(context, "delete", Arrays.asList(objects), true);
		return true;
	}

	public static boolean delete(IContext context, List<IMendixObject> objects) {
		store(context, "delete", objects, true);
		return true;
	}

	public static boolean delete(IContext context, List<IMendixObject> objects, boolean useDeleteBehavior) {
		return delete(context, objects);
	}

	public static boolean deleteWithoutEvents(IContext context, List<IMendixObject> objects, boolean useDeleteBehavior) {
		store(context, "delete", objects, false);
		return true;
	}

	public static IMendixObject rollback(IContext context, IMendixObject object) throws CoreException {
		store(context, "rollback", List.of(object), true);
		return object;
	}

	public static IMendixObject retrieveId(IContext context, IMendixIdentifier id) throws CoreException {
		return id == null ? null : id.getObject();
	}

	public static List<IMendixObject> retrieveIdList(IContext context, List<IMendixIdentifier> ids) throws CoreException {
		List<IMendixObject> objects = new ArrayList<>();
		for (IMendixIdentifier id : ids) {
			objects.add(retrieveId(context, id));
		}
		return objects;
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath) throws CoreException {
		return createXPathQuery(xpath).execute(context);
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath, int amount, int offset,
			Map<String, String> sort) throws CoreException {
		return retrieveXPathQuery(context, xpath, amount, offset, sort, 0);
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath, int amount, int offset,
			Map<String, String> sort, int depth) throws CoreException {
		XPathQuery query = createXPathQuery(xpath).setAmount(amount).setOffset(offset);
		sort.forEach((path, order) -> query.addSort(path, !"desc".equalsIgnoreCase(order)));
		return query.execute(context);
	}

	public static XPathQuery createXPathQuery(String xpath) {
		return new MxXPathQuery(xpath);
	}

	@SuppressWarnings("unchecked")
	public static List<IMendixObject> retrieveByPath(IContext context, IMendixObject object, String path) {
		return (List<IMendixObject>) bridge(context).call("related", "object", object, "association", path);
	}

	public static List<IMendixObject> retrieveByPath(IContext context, IMendixObject object, String path,
			boolean isSelfAssociationChild) {
		return retrieveByPath(context, object, path);
	}

	public static MicroflowCallBuilder microflowCall(String name) {
		return new MxMicroflowCall(name);
	}

	public static <R> R execute(IContext context, String microflow, Map<String, Object> parameters)
			throws CoreException {
		return microflowCall(microflow).withParams(parameters).execute(context);
	}

	public static IContext createSystemContext() {
		return new MxContext(Bridge.current(), true);
	}

	public static Configuration getConfiguration() {
		Bridge bridge = Bridge.current();
		return new Configuration() {
			@Override
			public String getApplicationRootUrl() {
				return (String) bridge.call("application_root_url");
			}

			@Override
			public Object getConstantValue(String name) {
				return bridge.call("constant", "name", name);
			}
		};
	}

	public static String getRuntimeVersion() {
		return (String) Bridge.current().call("runtime_version");
	}

	public static String getModelVersion() {
		return (String) Bridge.current().call("model_version");
	}

	private static Bridge bridge(IContext context) {
		return ((MxContext) context).bridge();
	}

	private static void store(IContext context, String method, List<IMendixObject> objects, boolean events) {
		bridge(context).call(method, "objects", objects, "events", events);
	}
}
