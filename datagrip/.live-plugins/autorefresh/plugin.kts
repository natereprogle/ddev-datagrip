// #ddev-generated

import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.extensions.PluginId
import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ProjectManager
import com.intellij.util.concurrency.AppExecutorUtil
import com.intellij.notification.NotificationType
import com.intellij.notification.NotificationType.ERROR
import liveplugin.PluginUtil.show
import java.util.concurrent.TimeUnit

fun runLater(seconds: Long, task: () -> Unit) {
    AppExecutorUtil.getAppScheduledExecutorService().schedule({
        ApplicationManager.getApplication().invokeLater {
            try {
                task()
            } catch (t: Throwable) {
                show("FAILED: ${t.javaClass.name}: ${t.message}", "DDEV DataGrip", NotificationType.ERROR)
                t.printStackTrace()
            }
        }
    }, seconds, TimeUnit.SECONDS)
}

fun dbClassLoader(): ClassLoader {
    val descriptor = PluginManagerCore.getPlugin(PluginId.getId("com.intellij.database"))
        ?: throw IllegalStateException("Database plugin com.intellij.database was not found")
    return descriptor.pluginClassLoader
        ?: throw IllegalStateException("Database plugin has no class loader")
}

fun loadDbClass(name: String): Class<*> = Class.forName(name, true, dbClassLoader())

private fun isCompatible(paramType: Class<*>, arg: Any?): Boolean {
    if (arg == null) return !paramType.isPrimitive
    val argClass = arg.javaClass
    if (paramType.isAssignableFrom(argClass)) return true
    // Handle primitive <-> wrapper equivalence
    return when (paramType) {
        java.lang.Boolean.TYPE -> argClass == java.lang.Boolean::class.java
        java.lang.Integer.TYPE -> argClass == java.lang.Integer::class.java
        java.lang.Long.TYPE -> argClass == java.lang.Long::class.java
        java.lang.Double.TYPE -> argClass == java.lang.Double::class.java
        java.lang.Float.TYPE -> argClass == java.lang.Float::class.java
        java.lang.Short.TYPE -> argClass == java.lang.Short::class.java
        java.lang.Byte.TYPE -> argClass == java.lang.Byte::class.java
        java.lang.Character.TYPE -> argClass == java.lang.Character::class.java
        else -> false
    }
}

fun invokeStatic(clazz: Class<*>, methodName: String, vararg args: Any?): Any? {
    val method = clazz.methods.find { m ->
        m.name == methodName &&
            m.parameterTypes.size == args.size &&
            args.withIndex().all { (i, arg) -> isCompatible(m.parameterTypes[i], arg) }
    } ?: throw NoSuchMethodException(
        "${clazz.name}.$methodName(${args.map { it?.javaClass?.name }})"
    )

    return method.invoke(null, *args)
}

fun invokeInstance(receiver: Any, methodName: String, vararg args: Any?): Any? {
    val method = receiver.javaClass.methods.find { m ->
        m.name == methodName &&
            m.parameterTypes.size == args.size &&
            args.withIndex().all { (i, arg) -> isCompatible(m.parameterTypes[i], arg) }
    } ?: throw NoSuchMethodException(
        "${receiver.javaClass.name}.$methodName(${args.map { it?.javaClass?.name }})"
    )

    return method.invoke(receiver, *args)
}

fun refreshProject(project: Project): Boolean {
    val dbPsiFacade = loadDbClass("com.intellij.database.psi.DbPsiFacade")
    val dbImplUtil = loadDbClass("com.intellij.database.util.DbImplUtil")
    val dataSourceUtil = loadDbClass("com.intellij.database.util.DataSourceUtil")

    val facade = invokeStatic(dbPsiFacade, "getInstance", project)!!
    @Suppress("UNCHECKED_CAST")
    val dataSources = invokeInstance(facade, "getDataSources") as Collection<Any>

    show("Found ${dataSources.size} data source(s) in ${project.name}", "DDEV DataGrip")

    if (dataSources.isEmpty()) {
        return false
    }

    dataSources.forEach { dbDataSource ->
        val dsName = invokeInstance(dbDataSource, "getName") as? String ?: "<unknown>"
        val localDataSource = invokeStatic(dbImplUtil, "getMaybeLocalDataSource", dbDataSource)

        if (localDataSource == null) {
            show("Skipping non-local datasource: $dsName", "DDEV DataGrip")
            return@forEach
        }

        invokeInstance(localDataSource, "setAutoSynchronize", true)
        invokeStatic(dataSourceUtil, "performAutoSyncTask", project, localDataSource)

        show("Triggered sync: $dsName", "DDEV DataGrip")
    }

    return true
}

val project = ProjectManager.getInstance().openProjects.find { !it.isDisposed }

if (project == null) {
    show("No open project", "DDEV DataGrip")
} else {
    listOf(5L).forEach { seconds ->
        runLater(seconds) {
            if (!project.isDisposed) {
                refreshProject(project)
            }
        }
    }

    show("The DDEV DataGrip Add-On has opened this project. Automatic refresh will happen shortly.", "DDEV DataGrip")
}